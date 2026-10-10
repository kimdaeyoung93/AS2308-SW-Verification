function [reversalTable, runData] = characterize_direction_reversal(varargin)
%CHARACTERIZE_DIRECTION_REVERSAL Characterize +/-15 rps reversals.
%
%   Runs +15 -> -15 rps and -15 -> +15 rps with both:
%     1) NominalConfiguration: reference filter 20/(s+20)
%     2) FilterBypassCharacterization: unity reference path
%
%   Name-value options:
%     'ReversalTime_s'        Time at which direction changes (default: 2)
%     'StopTime_s'            Simulation stop time (default: 5)
%     'SteadyStateWindow_s'   Final averaging window (default: 1)
%     'SettlingBand_pct'      Final-reference settling band (default: 2)
%     'ResultsDirectory'      CSV output directory
%
%   Post-reversal settling time is elapsed time from ReversalTime_s to the
%   first sample after which actual speed remains within the symmetric band
%   around the final command. NaN means it did not settle before StopTime_s.
%   Voltage extrema and saturation metrics use post-reversal samples only.
%   This function performs characterization only and makes no PASS/FAIL
%   decision.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'ReversalTime_s', 2, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
    addParameter(parser, 'StopTime_s', 5, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
    addParameter(parser, 'SteadyStateWindow_s', 1, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
    addParameter(parser, 'SettlingBand_pct', 2, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0 && x < 100);
    addParameter(parser, 'ResultsDirectory', '', ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    parse(parser, varargin{:});
    options = parser.Results;

    if options.ReversalTime_s >= options.StopTime_s
        error('characterize_direction_reversal:InvalidReversalTime', ...
            'ReversalTime_s must be smaller than StopTime_s.');
    end
    if options.SteadyStateWindow_s > ...
            options.StopTime_s - options.ReversalTime_s
        error('characterize_direction_reversal:InvalidSteadyStateWindow', ...
            'SteadyStateWindow_s must fit after ReversalTime_s.');
    end

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    modelDirectory = fullfile(repositoryRoot, 'model');
    modelName = 'AS2308_MIL_Baseline_v2';
    modelFile = fullfile(modelDirectory, [modelName, '.slx']);
    parameterScript = fullfile(modelDirectory, ...
        'AS2308_calculate_pi_control_cc.m');

    if strlength(string(options.ResultsDirectory)) == 0
        resultsDirectory = fullfile(repositoryRoot, 'results');
    else
        resultsDirectory = char(options.ResultsDirectory);
    end
    assert(isfile(modelFile), 'Model file not found: %s', modelFile);
    assert(isfile(parameterScript), 'Parameter script not found: %s', parameterScript);
    if ~isfolder(resultsDirectory)
        mkdir(resultsDirectory);
    end

    run(parameterScript);
    simulationVariables = struct( ...
        'ts', ts, 'Vdc', Vdc, 'Kps', Kps, 'Kis', Kis, 'Kas', Kas);

    modelWasLoaded = bdIsLoaded(modelName);
    load_system(modelFile);
    originalDirtyState = get_param(modelName, 'Dirty');

    loggingDefinitions = struct( ...
        'BlockPath', { ...
            [modelName, '/Transfer Fcn1'], ...
            [modelName, '/Transfer Fcn2'], ...
            [modelName, '/PI Speed Controller']}, ...
        'SignalName', { ...
            'speed_reference_rad_per_s', ...
            'actual_motor_speed_rad_per_s', ...
            'pi_controller_output_voltage_v'});
    loggingState = localEnableSignalLogging(loggingDefinitions);
    restoreModel = onCleanup(@() localRestoreModel( ...
        modelName, modelWasLoaded, originalDirtyState, loggingState)); %#ok<NASGU>

    pulseGenerator = localFindUniqueBlock(modelName, ...
        'BlockType', 'DiscretePulseGenerator');
    referenceOffset = [modelName, '/Constant2'];
    referenceSwitch = [modelName, '/Manual Switch'];
    referenceFilter = [modelName, '/Transfer Fcn1'];

    configuration = [ ...
        "NominalConfiguration"; ...
        "NominalConfiguration"; ...
        "FilterBypassCharacterization"; ...
        "FilterBypassCharacterization"];
    referenceFilterText = ["20/(s+20)"; "20/(s+20)"; "1"; "1"];
    initialReference = [15; -15; 15; -15];
    finalReference = -initialReference;
    transition = [ ...
        "+15_to_-15"; "-15_to_+15"; "+15_to_-15"; "-15_to_+15"];
    filterNumerator = {"[20]"; "[20]"; "[1]"; "[1]"};
    filterDenominator = {"[1 20]"; "[1 20]"; "[1]"; "[1]"};
    configurationFileLabel = ["nominal"; "nominal"; "bypass"; "bypass"];
    numberOfRuns = numel(configuration);

    finalSteadyStateSpeed = zeros(numberOfRuns, 1);
    steadyStateError = zeros(numberOfRuns, 1);
    postReversalSettlingTime = NaN(numberOfRuns, 1);
    maximumControllerVoltage = zeros(numberOfRuns, 1);
    minimumControllerVoltage = zeros(numberOfRuns, 1);
    positiveSaturationOccurred = false(numberOfRuns, 1);
    negativeSaturationOccurred = false(numberOfRuns, 1);
    saturationCumulativeTime = zeros(numberOfRuns, 1);
    samplesCsv = strings(numberOfRuns, 1);
    runData = repmat(struct( ...
        'Configuration', '', 'Transition', '', ...
        'Samples', table(), 'CsvFile', ''), numberOfRuns, 1);

    pulsePeriod_s = 2 * options.StopTime_s;
    pulseWidth_pct = 100 * options.ReversalTime_s / pulsePeriod_s;
    saturationTolerance_v = max(1e-9, 100 * eps(Vdc));

    for runIndex = 1:numberOfRuns
        initialDirection = sign(initialReference(runIndex));
        simulationInput = Simulink.SimulationInput(modelName);
        variableNames = fieldnames(simulationVariables);
        for variableIndex = 1:numel(variableNames)
            variableName = variableNames{variableIndex};
            simulationInput = simulationInput.setVariable( ...
                variableName, simulationVariables.(variableName));
        end

        % Pulse - Constant produces +1 -> -1 (or -1 -> +1), then Gain1
        % converts it to the requested +/-15 rps command. A long period
        % guarantees that only one reversal occurs during the simulation.
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'Amplitude', sprintf('%g', 2 * initialDirection));
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'Period', sprintf('%.17g', pulsePeriod_s));
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'PulseWidth', sprintf('%.17g', pulseWidth_pct));
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'PhaseDelay', '0');
        simulationInput = simulationInput.setBlockParameter( ...
            referenceOffset, 'Value', sprintf('%g', initialDirection));
        simulationInput = simulationInput.setBlockParameter( ...
            referenceSwitch, 'CurrentSetting', '1');
        simulationInput = simulationInput.setBlockParameter( ...
            referenceFilter, 'Numerator', char(filterNumerator{runIndex}));
        simulationInput = simulationInput.setBlockParameter( ...
            referenceFilter, 'Denominator', char(filterDenominator{runIndex}));
        simulationInput = simulationInput.setModelParameter( ...
            'StopTime', sprintf('%.17g', options.StopTime_s), ...
            'SignalLogging', 'on', ...
            'SignalLoggingName', 'logsout', ...
            'SignalLoggingSaveFormat', 'Dataset', ...
            'ReturnWorkspaceOutputs', 'on');

        simulationOutput = sim(simulationInput);
        loggedSignals = simulationOutput.get('logsout');
        referenceSignal = localGetLoggedSignal( ...
            loggedSignals, 'speed_reference_rad_per_s');
        speedSignal = localGetLoggedSignal( ...
            loggedSignals, 'actual_motor_speed_rad_per_s');
        voltageSignal = localGetLoggedSignal( ...
            loggedSignals, 'pi_controller_output_voltage_v');

        time = speedSignal.Time;
        reference_rps = localAlignSignal(referenceSignal, time) / (2 * pi);
        actualSpeed_rps = speedSignal.Data / (2 * pi);
        controllerVoltage_v = localAlignSignal(voltageSignal, time);
        samples = table(time, reference_rps, actualSpeed_rps, controllerVoltage_v, ...
            'VariableNames', { ...
                'Time_s', 'SpeedReference_rps', 'ActualMotorSpeed_rps', ...
                'PIControllerOutputVoltage_V'});

        steadyStateRows = time >= time(end) - options.SteadyStateWindow_s;
        finalSteadyStateSpeed(runIndex) = mean( ...
            actualSpeed_rps(steadyStateRows), 'omitnan');
        steadyStateError(runIndex) = 100 * ...
            (finalReference(runIndex) - finalSteadyStateSpeed(runIndex)) / ...
            finalReference(runIndex);

        postRows = time >= options.ReversalTime_s;
        postTime = time(postRows);
        postSpeed = actualSpeed_rps(postRows);
        postVoltage = controllerVoltage_v(postRows);
        settlingBand_rps = abs(finalReference(runIndex)) * ...
            options.SettlingBand_pct / 100;
        outsideSettlingBand = ~isfinite(postSpeed) | ...
            abs(postSpeed - finalReference(runIndex)) > settlingBand_rps;
        lastOutsideIndex = find(outsideSettlingBand, 1, 'last');
        if isempty(lastOutsideIndex)
            postReversalSettlingTime(runIndex) = 0;
        elseif lastOutsideIndex < numel(postTime)
            postReversalSettlingTime(runIndex) = ...
                postTime(lastOutsideIndex + 1) - options.ReversalTime_s;
        end

        maximumControllerVoltage(runIndex) = max(postVoltage, [], 'omitnan');
        minimumControllerVoltage(runIndex) = min(postVoltage, [], 'omitnan');
        positiveSaturation = postVoltage >= Vdc - saturationTolerance_v;
        negativeSaturation = postVoltage <= -Vdc + saturationTolerance_v;
        saturationIndicator = positiveSaturation | negativeSaturation;
        positiveSaturationOccurred(runIndex) = any(positiveSaturation);
        negativeSaturationOccurred(runIndex) = any(negativeSaturation);
        saturationCumulativeTime(runIndex) = trapz( ...
            postTime, double(saturationIndicator));

        runFileName = sprintf('direction_reversal_%s_%s.csv', ...
            char(configurationFileLabel(runIndex)), ...
            char(transition(runIndex)));
        runFile = fullfile(resultsDirectory, runFileName);
        writetable(samples, runFile);
        samplesCsv(runIndex) = string(runFile);
        runData(runIndex).Configuration = char(configuration(runIndex));
        runData(runIndex).Transition = char(transition(runIndex));
        runData(runIndex).Samples = samples;
        runData(runIndex).CsvFile = runFile;
    end

    reversalTime = repmat(options.ReversalTime_s, numberOfRuns, 1);
    settlingBand = repmat(options.SettlingBand_pct, numberOfRuns, 1);
    reversalTable = table( ...
        configuration, referenceFilterText, transition, initialReference, ...
        finalReference, finalSteadyStateSpeed, steadyStateError, ...
        postReversalSettlingTime, maximumControllerVoltage, ...
        minimumControllerVoltage, positiveSaturationOccurred, ...
        negativeSaturationOccurred, saturationCumulativeTime, ...
        reversalTime, settlingBand, samplesCsv, ...
        'VariableNames', { ...
            'Configuration', 'ReferenceFilter', 'Transition', ...
            'InitialReference_rps', 'FinalReference_rps', ...
            'FinalSteadyStateSpeed_rps', 'SteadyStateError_pct', ...
            'PostReversalSettlingTime_s', ...
            'MaximumPostReversalControllerVoltage_V', ...
            'MinimumPostReversalControllerVoltage_V', ...
            'Positive12VSaturationOccurred', ...
            'Negative12VSaturationOccurred', ...
            'PostReversalSaturationCumulativeTime_s', ...
            'ReversalTime_s', 'SettlingBand_pct', 'SamplesCsv'});

    summaryFile = fullfile(resultsDirectory, 'direction_reversal_summary.csv');
    writetable(reversalTable, summaryFile);
    fprintf('Direction-reversal summary written to: %s\n', summaryFile);
    disp(reversalTable);
end

function loggingState = localEnableSignalLogging(loggingDefinitions)
    numberOfSignals = numel(loggingDefinitions);
    loggingState = repmat(struct( ...
        'PortHandle', [], 'DataLogging', '', ...
        'DataLoggingNameMode', '', 'DataLoggingName', ''), numberOfSignals, 1);
    for signalIndex = 1:numberOfSignals
        blockPath = loggingDefinitions(signalIndex).BlockPath;
        portHandles = get_param(blockPath, 'PortHandles');
        portHandle = portHandles.Outport(1);
        assert(get_param(portHandle, 'Line') ~= -1, ...
            'Output port is not connected: %s', blockPath);
        loggingState(signalIndex).PortHandle = portHandle;
        loggingState(signalIndex).DataLogging = get_param(portHandle, 'DataLogging');
        loggingState(signalIndex).DataLoggingNameMode = ...
            get_param(portHandle, 'DataLoggingNameMode');
        loggingState(signalIndex).DataLoggingName = ...
            get_param(portHandle, 'DataLoggingName');
        set_param(portHandle, ...
            'DataLogging', 'on', 'DataLoggingNameMode', 'Custom', ...
            'DataLoggingName', loggingDefinitions(signalIndex).SignalName);
    end
end

function localRestoreModel(modelName, modelWasLoaded, dirtyState, loggingState)
    if ~bdIsLoaded(modelName)
        return;
    end
    for signalIndex = 1:numel(loggingState)
        state = loggingState(signalIndex);
        set_param(state.PortHandle, ...
            'DataLogging', state.DataLogging, ...
            'DataLoggingNameMode', state.DataLoggingNameMode, ...
            'DataLoggingName', state.DataLoggingName);
    end
    set_param(modelName, 'Dirty', dirtyState);
    if ~modelWasLoaded
        close_system(modelName, 0);
    end
end

function blockPath = localFindUniqueBlock(modelName, varargin)
    blocks = find_system(modelName, ...
        'SearchDepth', 1, 'LookUnderMasks', 'all', varargin{:});
    assert(numel(blocks) == 1, ...
        'Expected exactly one matching block, but found %d.', numel(blocks));
    blockPath = blocks{1};
end

function signal = localGetLoggedSignal(dataset, signalName)
    element = dataset.getElement(signalName);
    assert(~isempty(element), 'Logged signal not found: %s', signalName);
    values = element.Values;
    signal = struct( ...
        'Time', double(values.Time(:)), 'Data', double(values.Data(:)));
end

function alignedData = localAlignSignal(signal, targetTime)
    if isequal(signal.Time, targetTime)
        alignedData = signal.Data;
    elseif numel(signal.Time) == 1
        alignedData = repmat(signal.Data, size(targetTime));
    else
        alignedData = interp1( ...
            signal.Time, signal.Data, targetTime, 'linear', 'extrap');
    end
end
