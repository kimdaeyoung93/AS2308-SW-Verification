function [segmentTable, testSummary, runData] = ...
        run_repeated_reversal_test(varargin)
%RUN_REPEATED_REVERSAL_TEST Execute MTC-005 repeated reversals.
%
%   [SEGMENTTABLE, TESTSUMMARY, RUNDATA] = RUN_REPEATED_REVERSAL_TEST()
%   alternates +15 rps and -15 rps and evaluates the final plateau window
%   of every segment with the existing Direction and Tracking Oracles.
%
%   A segment passes only when direction_pass && tracking_pass. The overall
%   test passes only when every evaluated segment passes. This runner adds
%   no reversal settling-time, overshoot, or speed-tolerance criterion.
%
%   Name-value options:
%     'PlateauDuration_s'  Duration of each plateau (default: 2)
%     'RepeatCount'        Number of +15/-15 pairs (default: 3)
%
%   PlateauDuration_s and RepeatCount are test sequence execution
%   parameters. They are not product performance requirements. The plateau
%   duration must be longer than the existing Oracles' 0.05 s terminal
%   evaluation window so that each segment contains an evaluable plateau.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'PlateauDuration_s', 2, @localPositiveScalar);
    addParameter(parser, 'RepeatCount', 3, ...
        @(x) isnumeric(x) && isreal(x) && isscalar(x) && ...
        isfinite(x) && x >= 1 && x == floor(x));
    parse(parser, varargin{:});
    options = parser.Results;

    plateauDuration_s = double(options.PlateauDuration_s);
    repeatCount = double(options.RepeatCount);
    oracleEvaluationWindow_s = 0.05;
    if plateauDuration_s <= oracleEvaluationWindow_s
        error('run_repeated_reversal_test:PlateauTooShort', ...
            ['PlateauDuration_s must be longer than the existing ', ...
             '0.05 s Oracle evaluation window.']);
    end

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    modelDirectory = fullfile(repositoryRoot, 'model');
    oracleDirectory = fullfile(runnerDirectory, 'oracles');
    modelName = 'AS2308_MIL_Baseline_v2';
    modelFile = fullfile(modelDirectory, [modelName, '.slx']);
    parameterScript = fullfile( ...
        modelDirectory, 'AS2308_calculate_pi_control_cc.m');

    assert(isfile(modelFile), 'Model file not found: %s', modelFile);
    assert(isfile(parameterScript), ...
        'Parameter script not found: %s', parameterScript);
    assert(isfile(fullfile(oracleDirectory, 'evaluate_direction.m')), ...
        'Direction Oracle not found in: %s', oracleDirectory);
    assert(isfile(fullfile(oracleDirectory, 'evaluate_tracking.m')), ...
        'Tracking Oracle not found in: %s', oracleDirectory);

    addpath(oracleDirectory);
    run(parameterScript);
    simulationVariables = struct( ...
        'ts', ts, 'Vdc', Vdc, 'Kps', Kps, 'Kis', Kis, 'Kas', Kas, ...
        'SpeedRef_cmd', 0);

    modelWasLoaded = bdIsLoaded(modelName);
    load_system(modelFile);
    closeModel = onCleanup(@() localCloseModel(modelName, modelWasLoaded)); %#ok<NASGU>

    pulseGenerator = localFindUniqueBlock( ...
        modelName, 'BlockType', 'DiscretePulseGenerator');
    referenceOffset = [modelName, '/Constant2'];
    referenceSwitch = [modelName, '/Manual Switch'];

    total_segment_count = 2 * repeatCount;
    stopTime_s = total_segment_count * plateauDuration_s;
    pulsePeriod_s = 2 * plateauDuration_s;

    simulationInput = Simulink.SimulationInput(modelName);
    variableNames = fieldnames(simulationVariables);
    for variableIndex = 1:numel(variableNames)
        variableName = variableNames{variableIndex};
        simulationInput = simulationInput.setVariable( ...
            variableName, simulationVariables.(variableName));
    end

    % Pulse - Constant and the existing Gain1 produce alternating +15 rps
    % and -15 rps plateaus. A 50% pulse width gives equal plateau lengths.
    simulationInput = simulationInput.setBlockParameter( ...
        pulseGenerator, 'Amplitude', '2');
    simulationInput = simulationInput.setBlockParameter( ...
        pulseGenerator, 'Period', sprintf('%.17g', pulsePeriod_s));
    simulationInput = simulationInput.setBlockParameter( ...
        pulseGenerator, 'PulseWidth', '50');
    simulationInput = simulationInput.setBlockParameter( ...
        pulseGenerator, 'PhaseDelay', '0');
    simulationInput = simulationInput.setBlockParameter( ...
        referenceOffset, 'Value', '1');
    simulationInput = simulationInput.setBlockParameter( ...
        referenceSwitch, 'CurrentSetting', '1');
    simulationInput = simulationInput.setModelParameter( ...
        'StopTime', sprintf('%.17g', stopTime_s), ...
        'SignalLogging', 'on', ...
        'SignalLoggingName', 'logsout', ...
        'SignalLoggingSaveFormat', 'Dataset', ...
        'ReturnWorkspaceOutputs', 'on');

    fprintf('\nMTC-005 Repeated Direction Reversal\n');
    fprintf('Model: %s\n', modelName);
    fprintf(['Plateau duration: %.6g s; repeat count: %d ', ...
        '(test execution parameters)\n\n'], ...
        plateauDuration_s, repeatCount);

    simulationOutput = sim(simulationInput);
    loggedSignals = simulationOutput.get('logsout');
    referenceSignal = localGetLoggedSignal(loggedSignals, 'reference');
    motorSpeedSignal = localGetLoggedSignal(loggedSignals, 'motorspeed');

    time = double(motorSpeedSignal.Time(:));
    motorspeed = double(squeeze(motorSpeedSignal.Data));
    motorspeed = motorspeed(:);
    reference = localAlignSignal(referenceSignal, time);

    segment_id = strings(total_segment_count, 1);
    commanded_reference_rps = zeros(total_segment_count, 1);
    direction_pass = false(total_segment_count, 1);
    tracking_pass = false(total_segment_count, 1);
    overall_pass = false(total_segment_count, 1);
    tracking_max_abs_error_rps = NaN(total_segment_count, 1);
    direction_mismatch_sample_count = NaN(total_segment_count, 1);
    segmentData = repmat(struct( ...
        'segment_id', "", ...
        'samples', table(), ...
        'direction_result', struct(), ...
        'tracking_result', struct()), total_segment_count, 1);

    for segmentIndex = 1:total_segment_count
        segment_id(segmentIndex) = sprintf( ...
            'MTC-005-S%02d', segmentIndex);
        if mod(segmentIndex, 2) == 1
            commanded_reference_rps(segmentIndex) = 15;
        else
            commanded_reference_rps(segmentIndex) = -15;
        end

        segmentStart_s = (segmentIndex - 1) * plateauDuration_s;
        segmentEnd_s = segmentIndex * plateauDuration_s;
        segmentRows = time >= segmentStart_s & time < segmentEnd_s;
        if ~any(segmentRows)
            error('run_repeated_reversal_test:EmptySegment', ...
                'No logged samples were found for segment %d.', segmentIndex);
        end

        segmentTime = time(segmentRows);
        segmentReference = reference(segmentRows);
        segmentMotorSpeed = motorspeed(segmentRows);
        expectedReference = commanded_reference_rps(segmentIndex);
        if any(segmentReference ~= expectedReference)
            error('run_repeated_reversal_test:UnexpectedReference', ...
                ['Logged reference does not match the commanded %.17g rps ', ...
                 'plateau in segment %d.'], expectedReference, segmentIndex);
        end

        directionResult = evaluate_direction( ...
            segmentTime, segmentReference, segmentMotorSpeed);
        trackingResult = evaluate_tracking( ...
            segmentTime, segmentReference, segmentMotorSpeed);

        direction_pass(segmentIndex) = directionResult.pass;
        tracking_pass(segmentIndex) = trackingResult.pass;
        overall_pass(segmentIndex) = ...
            directionResult.pass && trackingResult.pass;
        tracking_max_abs_error_rps(segmentIndex) = ...
            trackingResult.max_abs_error_rps;
        direction_mismatch_sample_count(segmentIndex) = ...
            directionResult.mismatch_sample_count;

        segmentData(segmentIndex).segment_id = segment_id(segmentIndex);
        segmentData(segmentIndex).samples = table( ...
            segmentTime, segmentReference, segmentMotorSpeed, ...
            'VariableNames', {'time_s', 'reference_rps', 'motorspeed_rps'});
        segmentData(segmentIndex).direction_result = directionResult;
        segmentData(segmentIndex).tracking_result = trackingResult;

        fprintf(['%s | command %+g rps | direction %s | tracking %s | ', ...
            'overall %s | max tracking error %.12g rps | ', ...
            'direction mismatches %d\n'], ...
            segment_id(segmentIndex), commanded_reference_rps(segmentIndex), ...
            localPassFail(direction_pass(segmentIndex)), ...
            localPassFail(tracking_pass(segmentIndex)), ...
            localPassFail(overall_pass(segmentIndex)), ...
            tracking_max_abs_error_rps(segmentIndex), ...
            direction_mismatch_sample_count(segmentIndex));
    end

    segmentTable = table( ...
        segment_id, commanded_reference_rps, direction_pass, tracking_pass, ...
        overall_pass, tracking_max_abs_error_rps, ...
        direction_mismatch_sample_count);

    passed_segment_count = sum(overall_pass);
    overall_test_pass = all(overall_pass);
    testSummary = struct( ...
        'total_segment_count', total_segment_count, ...
        'passed_segment_count', passed_segment_count, ...
        'overall_test_pass', overall_test_pass);
    runData = struct( ...
        'samples', table(time, reference, motorspeed, ...
            'VariableNames', {'time_s', 'reference_rps', 'motorspeed_rps'}), ...
        'segments', segmentData);

    fprintf('\nPassed segments: %d/%d | overall test %s\n\n', ...
        passed_segment_count, total_segment_count, ...
        localPassFail(overall_test_pass));
    disp(segmentTable);
    disp(testSummary);
end

function value = localAlignSignal(signal, targetTime)
    signalTime = double(signal.Time(:));
    signalData = double(squeeze(signal.Data));
    signalData = signalData(:);

    if isequal(signalTime, targetTime)
        value = signalData;
    else
        value = interp1( ...
            signalTime, signalData, targetTime, 'previous', 'extrap');
    end
end

function signal = localGetLoggedSignal(loggedSignals, signalName)
    signalElement = loggedSignals.get(signalName);
    if isempty(signalElement)
        error('run_repeated_reversal_test:MissingSignal', ...
            'Logged signal "%s" was not found.', signalName);
    end
    signal = signalElement.Values;
end

function blockPath = localFindUniqueBlock(modelName, varargin)
    blocks = find_system(modelName, ...
        'LookUnderMasks', 'all', 'FollowLinks', 'on', varargin{:});
    if numel(blocks) ~= 1
        error('run_repeated_reversal_test:UnexpectedBlockCount', ...
            'Expected one matching block, found %d.', numel(blocks));
    end
    blockPath = blocks{1};
end

function text = localPassFail(pass)
    if pass
        text = 'PASS';
    else
        text = 'FAIL';
    end
end

function valid = localPositiveScalar(value)
    valid = isnumeric(value) && isreal(value) && isscalar(value) && ...
        isfinite(value) && value > 0;
end

function localCloseModel(modelName, modelWasLoaded)
    if ~modelWasLoaded && bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end
