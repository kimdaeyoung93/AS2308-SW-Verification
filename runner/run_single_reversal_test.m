function [resultTable, runData] = run_single_reversal_test(varargin)
%RUN_SINGLE_REVERSAL_TEST Execute MTC-004 single direction reversals.
%
%   [RESULTTABLE, RUNDATA] = RUN_SINGLE_REVERSAL_TEST() executes:
%     MTC-004-01: +15 rps -> -15 rps
%     MTC-004-02: -15 rps -> +15 rps
%
%   The pre-reversal plateau is first evaluated by the existing Direction
%   and Tracking Oracles. Only an established setup permits evaluation of
%   the post-reversal plateau. This is additional evaluation within the
%   existing simulation, not another top-level execution.
%
%   Name-value options:
%     'SwitchingTime_s'  Reference switching time (default: 2)
%     'StopTime_s'       Simulation stop time (default: 4)
%     'ModelName'        Simulink model name
%                        (default: AS2308_MIL_Baseline_v3)
%
%   SwitchingTime_s and StopTime_s are test execution parameters used to
%   provide initial and final plateaus. They are not product performance
%   requirements or Oracle thresholds.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'SwitchingTime_s', 2, @localPositiveScalar);
    addParameter(parser, 'StopTime_s', 4, @localPositiveScalar);
    addParameter(parser, 'ModelName', 'AS2308_MIL_Baseline_v3', ...
        @(x) (ischar(x) && ~isempty(x)) || ...
        (isstring(x) && isscalar(x) && strlength(x) > 0));
    parse(parser, varargin{:});
    options = parser.Results;

    switchingTime_s = double(options.SwitchingTime_s);
    stopTime_s = double(options.StopTime_s);
    modelName = char(string(options.ModelName));
    if switchingTime_s >= stopTime_s
        error('run_single_reversal_test:InvalidSwitchingTime', ...
            'SwitchingTime_s must be smaller than StopTime_s.');
    end

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    modelDirectory = fullfile(repositoryRoot, 'model');
    oracleDirectory = fullfile(runnerDirectory, 'oracles');
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
    closeModel = onCleanup(@() localCloseModel(modelName, modelWasLoaded));
    assert(isa(closeModel, 'onCleanup'));

    pulseGenerator = localFindUniqueBlock( ...
        modelName, 'BlockType', 'DiscretePulseGenerator');
    referenceOffset = [modelName, '/Constant2'];
    referenceSwitch = [modelName, '/Manual Switch'];

    iteration_id = ["MTC-004-01"; "MTC-004-02"];
    initial_reference_rps = [15; -15];
    reversed_reference_rps = -initial_reference_rps;
    numberOfIterations = numel(iteration_id);

    direction_pass = false(numberOfIterations, 1);
    tracking_pass = false(numberOfIterations, 1);
    overall_pass = false(numberOfIterations, 1);
    setup_direction_pass = false(numberOfIterations, 1);
    setup_tracking_pass = false(numberOfIterations, 1);
    setup_established = false(numberOfIterations, 1);
    status = strings(numberOfIterations, 1);
    tracking_max_abs_error_rps = NaN(numberOfIterations, 1);
    direction_mismatch_sample_count = NaN(numberOfIterations, 1);
    runData = repmat(struct( ...
        'iteration_id', "", ...
        'samples', table(), ...
        'setup_direction_result', struct(), ...
        'setup_tracking_result', struct(), ...
        'direction_result', struct(), ...
        'tracking_result', struct(), ...
        'status', "", ...
        'error_message', ""), numberOfIterations, 1);

    pulsePeriod_s = 2 * stopTime_s;
    pulseWidth_pct = 100 * switchingTime_s / pulsePeriod_s;

    fprintf('\nMTC-004 Single Direction Reversal\n');
    fprintf('Model: %s\n', modelName);
    fprintf(['Switching time: %.6g s; stop time: %.6g s ', ...
        '(test execution parameters)\n\n'], ...
        switchingTime_s, stopTime_s);

    for iterationIndex = 1:numberOfIterations
        initialDirection = sign(initial_reference_rps(iterationIndex));
        simulationInput = Simulink.SimulationInput(modelName);

        variableNames = fieldnames(simulationVariables);
        for variableIndex = 1:numel(variableNames)
            variableName = variableNames{variableIndex};
            simulationInput = simulationInput.setVariable( ...
                variableName, simulationVariables.(variableName));
        end

        % Pulse - Constant produces +1 -> -1 or -1 -> +1. Gain1 in the
        % existing model converts that sequence to +/-15 rps. The period
        % is longer than the run so exactly one reversal occurs.
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, ...
            'Amplitude', sprintf('%g', 2 * initialDirection));
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'Period', sprintf('%.17g', pulsePeriod_s));
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, ...
            'PulseWidth', sprintf('%.17g', pulseWidth_pct));
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'PhaseDelay', '0');
        simulationInput = simulationInput.setBlockParameter( ...
            referenceOffset, 'Value', sprintf('%g', initialDirection));
        simulationInput = simulationInput.setBlockParameter( ...
            referenceSwitch, 'CurrentSetting', '1');
        simulationInput = simulationInput.setModelParameter( ...
            'StopTime', sprintf('%.17g', stopTime_s), ...
            'SignalLogging', 'on', ...
            'SignalLoggingName', 'logsout', ...
            'SignalLoggingSaveFormat', 'Dataset', ...
            'ReturnWorkspaceOutputs', 'on');

        simulationOutput = sim(simulationInput);
        loggedSignals = simulationOutput.get('logsout');
        referenceSignal = localGetLoggedSignal(loggedSignals, 'reference');
        motorSpeedSignal = localGetLoggedSignal(loggedSignals, 'motorspeed');

        time = double(motorSpeedSignal.Time(:));
        motorspeed = double(squeeze(motorSpeedSignal.Data));
        motorspeed = motorspeed(:);
        reference = localAlignSignal(referenceSignal, time);

        preRows = time < switchingTime_s;
        postRows = time >= switchingTime_s;
        assert(any(preRows) && any(postRows), ...
            'run_single_reversal_test:MissingPlateau', ...
            'Both pre- and post-reversal plateaus must contain samples.');

        setupDirectionResult = evaluate_direction( ...
            time(preRows), reference(preRows), motorspeed(preRows));
        setupTrackingResult = evaluate_tracking( ...
            time(preRows), reference(preRows), motorspeed(preRows));
        setup_direction_pass(iterationIndex) = setupDirectionResult.pass;
        setup_tracking_pass(iterationIndex) = setupTrackingResult.pass;
        setup_established(iterationIndex) = ...
            setupDirectionResult.pass && setupTrackingResult.pass;

        directionResult = struct();
        trackingResult = struct();
        if setup_established(iterationIndex)
            directionResult = evaluate_direction( ...
                time(postRows), reference(postRows), motorspeed(postRows));
            trackingResult = evaluate_tracking( ...
                time(postRows), reference(postRows), motorspeed(postRows));
            direction_pass(iterationIndex) = directionResult.pass;
            tracking_pass(iterationIndex) = trackingResult.pass;
            overall_pass(iterationIndex) = ...
                directionResult.pass && trackingResult.pass;
            tracking_max_abs_error_rps(iterationIndex) = ...
                trackingResult.max_abs_error_rps;
            direction_mismatch_sample_count(iterationIndex) = ...
                directionResult.mismatch_sample_count;
            status(iterationIndex) = localPassFail( ...
                overall_pass(iterationIndex));
        else
            status(iterationIndex) = "INCONCLUSIVE_PRECONDITION";
        end

        runData(iterationIndex).iteration_id = ...
            iteration_id(iterationIndex);
        runData(iterationIndex).samples = table( ...
            time, reference, motorspeed, ...
            'VariableNames', {'time_s', 'reference_rps', 'motorspeed_rps'});
        runData(iterationIndex).setup_direction_result = ...
            setupDirectionResult;
        runData(iterationIndex).setup_tracking_result = ...
            setupTrackingResult;
        runData(iterationIndex).direction_result = directionResult;
        runData(iterationIndex).tracking_result = trackingResult;
        runData(iterationIndex).status = status(iterationIndex);

        fprintf(['%s | %+g -> %+g rps | setup %s | direction %s | ', ...
            'tracking %s | status %s | max tracking error %.12g rps | ', ...
            'direction mismatches %d\n'], ...
            iteration_id(iterationIndex), ...
            initial_reference_rps(iterationIndex), ...
            reversed_reference_rps(iterationIndex), ...
            localPassFail(setup_established(iterationIndex)), ...
            localPassFail(direction_pass(iterationIndex)), ...
            localPassFail(tracking_pass(iterationIndex)), ...
            status(iterationIndex), ...
            tracking_max_abs_error_rps(iterationIndex), ...
            direction_mismatch_sample_count(iterationIndex));
    end

    resultTable = table( ...
        iteration_id, initial_reference_rps, reversed_reference_rps, ...
        setup_direction_pass, setup_tracking_pass, setup_established, ...
        direction_pass, tracking_pass, overall_pass, ...
        status, tracking_max_abs_error_rps, ...
        direction_mismatch_sample_count);

    fprintf('\n');
    disp(resultTable);
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
        error('run_single_reversal_test:MissingSignal', ...
            'Logged signal "%s" was not found.', signalName);
    end
    signal = signalElement.Values;
end

function blockPath = localFindUniqueBlock(modelName, varargin)
    blocks = find_system(modelName, ...
        'LookUnderMasks', 'all', 'FollowLinks', 'on', varargin{:});
    if numel(blocks) ~= 1
        error('run_single_reversal_test:UnexpectedBlockCount', ...
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
