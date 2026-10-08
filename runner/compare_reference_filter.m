function [comparisonTable, runData] = compare_reference_filter(varargin)
%COMPARE_REFERENCE_FILTER Compare filtered and unfiltered +15 rps responses.
%
%   [COMPARISONTABLE, RUNDATA] = COMPARE_REFERENCE_FILTER() runs the same
%   normal PI controller and first-order plant twice. The first run uses the
%   baseline reference filter 20/(s+20); the second run bypasses it with a
%   unity transfer function. No controller or plant parameter is changed.
%
%   Name-value options:
%     'StopTime_s'          Simulation stop time in seconds (default: 5)
%     'SettlingBand_pct'    Symmetric settling band (default: 2)
%     'ResultsDirectory'    Directory in which CSV files are written
%
%   Overshoot is calculated in the command direction:
%     max(0, (directed peak - abs(command)) / abs(command) * 100)
%
%   Settling time is the first time after which actual speed remains within
%   command +/- SettlingBand_pct through the end of the simulation. The band
%   is a metric definition only; this function makes no PASS/FAIL decision.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'StopTime_s', 5, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
    addParameter(parser, 'SettlingBand_pct', 2, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0 && x < 100);
    addParameter(parser, 'ResultsDirectory', '', ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    parse(parser, varargin{:});
    options = parser.Results;

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    modelDirectory = fullfile(repositoryRoot, 'model');
    modelName = 'AS2308_MIL_Baseline_v1';
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
        'ts', ts, ...
        'Vdc', Vdc, ...
        'Kps', Kps, ...
        'Kis', Kis, ...
        'Kas', Kas);

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

    commandedReference = 15;
    caseNames = ["FilterApplied"; "FilterBypassed"];
    filterTransferFunctions = ["20/(s+20)"; "1"];
    filterNumerators = {"[20]"; "[1]"};
    filterDenominators = {"[1 20]"; "[1]"};
    fileLabels = ["applied"; "bypassed"];
    numberOfRuns = numel(caseNames);

    peakSpeed = zeros(numberOfRuns, 1);
    overshoot = zeros(numberOfRuns, 1);
    settlingTime = NaN(numberOfRuns, 1);
    maximumControllerVoltage = zeros(numberOfRuns, 1);
    minimumControllerVoltage = zeros(numberOfRuns, 1);
    samplesCsv = strings(numberOfRuns, 1);
    runData = repmat(struct( ...
        'Case', '', 'Samples', table(), 'CsvFile', ''), numberOfRuns, 1);

    for runIndex = 1:numberOfRuns
        simulationInput = Simulink.SimulationInput(modelName);
        variableNames = fieldnames(simulationVariables);
        for variableIndex = 1:numel(variableNames)
            variableName = variableNames{variableIndex};
            simulationInput = simulationInput.setVariable( ...
                variableName, simulationVariables.(variableName));
        end

        % Generate the same constant +15 rps command for both runs. Only the
        % existing reference-filter block is changed between simulations.
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'Amplitude', '0');
        simulationInput = simulationInput.setBlockParameter( ...
            referenceOffset, 'Value', sprintf('%.17g', -commandedReference / 15));
        simulationInput = simulationInput.setBlockParameter( ...
            referenceSwitch, 'CurrentSetting', '1');
        simulationInput = simulationInput.setBlockParameter( ...
            referenceFilter, ...
            'Numerator', char(filterNumerators{runIndex}));
        simulationInput = simulationInput.setBlockParameter( ...
            referenceFilter, ...
            'Denominator', char(filterDenominators{runIndex}));
        simulationInput = simulationInput.setModelParameter( ...
            'StopTime', sprintf('%.17g', options.StopTime_s), ...
            'SignalLogging', 'on', ...
            'SignalLoggingName', 'logsout', ...
            'SignalLoggingSaveFormat', 'Dataset', ...
            'ReturnWorkspaceOutputs', 'on');

        simulationOutput = sim(simulationInput);
        loggedSignals = simulationOutput.get('logsout');
        assert(isa(loggedSignals, 'Simulink.SimulationData.Dataset'), ...
            'Expected signal logging output "logsout" was not produced.');

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
                'Time_s', ...
                'SpeedReference_rps', ...
                'ActualMotorSpeed_rps', ...
                'PIControllerOutputVoltage_V'});

        commandDirection = sign(commandedReference);
        directedPeak = max(commandDirection * actualSpeed_rps, [], 'omitnan');
        peakSpeed(runIndex) = commandDirection * directedPeak;
        overshoot(runIndex) = max(0, 100 * ...
            (directedPeak - abs(commandedReference)) / abs(commandedReference));

        settlingBand_rps = abs(commandedReference) * ...
            options.SettlingBand_pct / 100;
        outsideSettlingBand = ~isfinite(actualSpeed_rps) | ...
            abs(actualSpeed_rps - commandedReference) > settlingBand_rps;
        lastOutsideIndex = find(outsideSettlingBand, 1, 'last');
        if isempty(lastOutsideIndex)
            settlingTime(runIndex) = time(1);
        elseif lastOutsideIndex < numel(time)
            settlingTime(runIndex) = time(lastOutsideIndex + 1);
        end

        maximumControllerVoltage(runIndex) = max( ...
            controllerVoltage_v, [], 'omitnan');
        minimumControllerVoltage(runIndex) = min( ...
            controllerVoltage_v, [], 'omitnan');

        runFileName = sprintf('reference_filter_%s_15_rps.csv', ...
            char(fileLabels(runIndex)));
        runFile = fullfile(resultsDirectory, runFileName);
        writetable(samples, runFile);

        samplesCsv(runIndex) = string(runFile);
        runData(runIndex).Case = char(caseNames(runIndex));
        runData(runIndex).Samples = samples;
        runData(runIndex).CsvFile = runFile;
    end

    commandedReferences = repmat(commandedReference, numberOfRuns, 1);
    stopTime = repmat(options.StopTime_s, numberOfRuns, 1);
    settlingBand = repmat(options.SettlingBand_pct, numberOfRuns, 1);
    comparisonTable = table( ...
        caseNames, filterTransferFunctions, commandedReferences, ...
        peakSpeed, overshoot, settlingTime, ...
        maximumControllerVoltage, minimumControllerVoltage, ...
        stopTime, settlingBand, samplesCsv, ...
        'VariableNames', { ...
            'Case', ...
            'ReferenceFilter', ...
            'CommandedSpeedReference_rps', ...
            'PeakSpeed_rps', ...
            'Overshoot_pct', ...
            'SettlingTime_s', ...
            'MaximumControllerVoltage_V', ...
            'MinimumControllerVoltage_V', ...
            'SimulationStopTime_s', ...
            'SettlingBand_pct', ...
            'SamplesCsv'});

    summaryFile = fullfile( ...
        resultsDirectory, 'reference_filter_comparison_summary.csv');
    writetable(comparisonTable, summaryFile);
    fprintf('Reference-filter comparison written to: %s\n', summaryFile);
    disp(comparisonTable);
end

function loggingState = localEnableSignalLogging(loggingDefinitions)
    numberOfSignals = numel(loggingDefinitions);
    loggingState = repmat(struct( ...
        'PortHandle', [], ...
        'DataLogging', '', ...
        'DataLoggingNameMode', '', ...
        'DataLoggingName', ''), numberOfSignals, 1);

    for signalIndex = 1:numberOfSignals
        blockPath = loggingDefinitions(signalIndex).BlockPath;
        assert(getSimulinkBlockHandle(blockPath) ~= -1, ...
            'Required block not found: %s', blockPath);
        portHandles = get_param(blockPath, 'PortHandles');
        assert(~isempty(portHandles.Outport), ...
            'Block has no output port: %s', blockPath);
        portHandle = portHandles.Outport(1);
        lineHandle = get_param(portHandle, 'Line');
        assert(lineHandle ~= -1, ...
            'Output port is not connected: %s', blockPath);

        loggingState(signalIndex).PortHandle = portHandle;
        loggingState(signalIndex).DataLogging = ...
            get_param(portHandle, 'DataLogging');
        loggingState(signalIndex).DataLoggingNameMode = ...
            get_param(portHandle, 'DataLoggingNameMode');
        loggingState(signalIndex).DataLoggingName = ...
            get_param(portHandle, 'DataLoggingName');

        set_param(portHandle, ...
            'DataLogging', 'on', ...
            'DataLoggingNameMode', 'Custom', ...
            'DataLoggingName', loggingDefinitions(signalIndex).SignalName);
    end
end

function localRestoreModel(modelName, modelWasLoaded, dirtyState, loggingState)
    if ~bdIsLoaded(modelName)
        return;
    end

    for signalIndex = 1:numel(loggingState)
        state = loggingState(signalIndex);
        try
            set_param(state.PortHandle, ...
                'DataLogging', state.DataLogging, ...
                'DataLoggingNameMode', state.DataLoggingNameMode, ...
                'DataLoggingName', state.DataLoggingName);
        catch exception
            warning('compare_reference_filter:LoggingRestoreFailed', ...
                'Could not restore logging for port handle %g: %s', ...
                state.PortHandle, exception.message);
        end
    end
    set_param(modelName, 'Dirty', dirtyState);

    if ~modelWasLoaded
        close_system(modelName, 0);
    end
end

function blockPath = localFindUniqueBlock(modelName, varargin)
    blocks = find_system(modelName, ...
        'SearchDepth', 1, ...
        'LookUnderMasks', 'all', ...
        varargin{:});
    assert(numel(blocks) == 1, ...
        'Expected exactly one matching block, but found %d.', numel(blocks));
    blockPath = blocks{1};
end

function signal = localGetLoggedSignal(dataset, signalName)
    element = dataset.getElement(signalName);
    assert(~isempty(element), 'Logged signal not found: %s', signalName);
    values = element.Values;
    assert(isa(values, 'timeseries'), ...
        'Logged signal "%s" is not a timeseries.', signalName);

    signal = struct( ...
        'Time', double(values.Time(:)), ...
        'Data', double(values.Data(:)));
    assert(numel(signal.Time) == numel(signal.Data), ...
        'Time and data lengths differ for signal: %s', signalName);
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
