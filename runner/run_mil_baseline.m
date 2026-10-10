function [summaryTable, runData] = run_mil_baseline(varargin)
%RUN_MIL_BASELINE Repeatedly run the AS2308 MIL model at fixed speed references.
%
%   [SUMMARYTABLE, RUNDATA] = RUN_MIL_BASELINE() runs the model for
%   +5, +10, +15, -5, -10, and -15 rps. Each simulation runs for 5 seconds and the
%   final 1 second is used to calculate the steady-state values.
%
%   Name-value options:
%     'References_rps'           Numeric vector of nonzero references
%     'StopTime_s'               Simulation stop time in seconds
%     'SteadyStateWindow_s'      Final time window used for averaging
%     'SettlingBand_pct'         Symmetric settling band around the command
%     'ResultsDirectory'         Directory in which CSV files are written
%
%   Metric definitions:
%     steady-state speed = mean actual speed over the final steady-state window
%     steady-state error = (command - steady-state speed) / command * 100
%     peak speed         = farthest speed reached in the command direction
%     overshoot          = max(0, (directed peak - abs(command)) /
%                              abs(command) * 100)
%     settling time      = first time after which actual speed remains inside
%                          command +/- SettlingBand_pct for the rest of the run
%     saturation time    = time integral of the +/-Vdc saturation indicator
%
%   SettlingBand_pct defines a measurement band only. It is not an
%   acceptance criterion and this function performs no PASS/FAIL decision.
%
%   The model file is not modified. Input block parameters and signal
%   logging are overridden only for the duration of this function.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'References_rps', [5, 10, 15, -5, -10, -15], ...
        @(x) isnumeric(x) && isvector(x) && all(isfinite(x)) && all(x ~= 0));
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

    if options.SteadyStateWindow_s > options.StopTime_s
        error('run_mil_baseline:InvalidSteadyStateWindow', ...
            'SteadyStateWindow_s must not exceed StopTime_s.');
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

    % Load the unchanged controller parameters into this function workspace.
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

    references = options.References_rps(:);
    numberOfRuns = numel(references);
    steadyStateReference = zeros(numberOfRuns, 1);
    steadyStateSpeed = zeros(numberOfRuns, 1);
    steadyStateError = zeros(numberOfRuns, 1);
    peakSpeed = zeros(numberOfRuns, 1);
    overshoot = zeros(numberOfRuns, 1);
    settlingTime = NaN(numberOfRuns, 1);
    maximumControllerVoltage = zeros(numberOfRuns, 1);
    minimumControllerVoltage = zeros(numberOfRuns, 1);
    positiveSaturationOccurred = false(numberOfRuns, 1);
    negativeSaturationOccurred = false(numberOfRuns, 1);
    saturationCumulativeTime = zeros(numberOfRuns, 1);
    samplesCsv = strings(numberOfRuns, 1);
    runData = repmat(struct( ...
        'Reference_rps', [], 'Samples', table(), 'CsvFile', ''), numberOfRuns, 1);

    for runIndex = 1:numberOfRuns
        commandedReference = references(runIndex);

        simulationInput = Simulink.SimulationInput(modelName);
        variableNames = fieldnames(simulationVariables);
        for variableIndex = 1:numel(variableNames)
            variableName = variableNames{variableIndex};
            simulationInput = simulationInput.setVariable( ...
                variableName, simulationVariables.(variableName));
        end

        % The existing top input path is:
        % Pulse Generator1 - Constant2 -> Gain1 (15) -> Manual Switch.
        % Set the pulse amplitude to zero and choose Constant2 so the Gain1
        % output is the requested constant speed. These are per-run
        % overrides and are never saved to the SLX file.
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'Amplitude', '0');
        simulationInput = simulationInput.setBlockParameter( ...
            referenceOffset, 'Value', sprintf('%.17g', -commandedReference / 15));
        simulationInput = simulationInput.setBlockParameter( ...
            referenceSwitch, 'CurrentSetting', '1');
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

        steadyStateStart = time(end) - options.SteadyStateWindow_s;
        steadyStateRows = time >= steadyStateStart;
        assert(any(steadyStateRows), ...
            'No samples were found in the steady-state window.');

        steadyStateReference(runIndex) = mean( ...
            reference_rps(steadyStateRows), 'omitnan');
        steadyStateSpeed(runIndex) = mean( ...
            actualSpeed_rps(steadyStateRows), 'omitnan');
        steadyStateError(runIndex) = 100 * ...
            (commandedReference - steadyStateSpeed(runIndex)) / commandedReference;

        % Direction-normalized peak calculation makes the same formula valid
        % for positive and negative commands. For example, the directional
        % peak for -10 rps is max(-actualSpeed), and PeakSpeed_rps is then
        % converted back to a negative physical speed.
        commandDirection = sign(commandedReference);
        directedPeak = max(commandDirection * actualSpeed_rps, [], 'omitnan');
        peakSpeed(runIndex) = commandDirection * directedPeak;
        overshoot(runIndex) = max(0, 100 * ...
            (directedPeak - abs(commandedReference)) / abs(commandedReference));

        % Settling time is measured against a symmetric percentage band
        % around the commanded speed. It is the first sample after the last
        % out-of-band sample. NaN means the response did not settle by the
        % simulation stop time.
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

        % The controller saturation limits are the unchanged +/-Vdc values
        % from AS2308_calculate_pi_control_cc.m (Vdc = 12 V). A small numeric
        % tolerance avoids missing a clamped sample due to round-off.
        saturationTolerance_v = max(1e-9, 100 * eps(Vdc));
        positiveSaturation = controllerVoltage_v >= Vdc - saturationTolerance_v;
        negativeSaturation = controllerVoltage_v <= -Vdc + saturationTolerance_v;
        saturationIndicator = positiveSaturation | negativeSaturation;
        positiveSaturationOccurred(runIndex) = any(positiveSaturation);
        negativeSaturationOccurred(runIndex) = any(negativeSaturation);
        saturationCumulativeTime(runIndex) = trapz( ...
            time, double(saturationIndicator));

        runFileName = sprintf('mil_run_%s_rps.csv', ...
            localReferenceLabel(commandedReference));
        runFile = fullfile(resultsDirectory, runFileName);
        writetable(samples, runFile);

        samplesCsv(runIndex) = string(runFile);
        runData(runIndex).Reference_rps = commandedReference;
        runData(runIndex).Samples = samples;
        runData(runIndex).CsvFile = runFile;
    end

    runNumber = (1:numberOfRuns).';
    stopTime = repmat(options.StopTime_s, numberOfRuns, 1);
    steadyStateWindow = repmat(options.SteadyStateWindow_s, numberOfRuns, 1);
    settlingBand = repmat(options.SettlingBand_pct, numberOfRuns, 1);
    summaryTable = table( ...
        runNumber, references, steadyStateReference, steadyStateSpeed, ...
        steadyStateError, peakSpeed, overshoot, settlingTime, ...
        maximumControllerVoltage, minimumControllerVoltage, ...
        positiveSaturationOccurred, negativeSaturationOccurred, ...
        saturationCumulativeTime, stopTime, steadyStateWindow, ...
        settlingBand, samplesCsv, ...
        'VariableNames', { ...
            'Run', ...
            'CommandedSpeedReference_rps', ...
            'LoggedSteadyStateReference_rps', ...
            'SteadyStateSpeed_rps', ...
            'SteadyStateError_pct', ...
            'PeakSpeed_rps', ...
            'Overshoot_pct', ...
            'SettlingTime_s', ...
            'MaximumControllerVoltage_V', ...
            'MinimumControllerVoltage_V', ...
            'Positive12VSaturationOccurred', ...
            'Negative12VSaturationOccurred', ...
            'SaturationCumulativeTime_s', ...
            'SimulationStopTime_s', ...
            'SteadyStateWindow_s', ...
            'SettlingBand_pct', ...
            'SamplesCsv'});

    summaryFile = fullfile(resultsDirectory, 'mil_summary.csv');
    writetable(summaryTable, summaryFile);
    fprintf('MIL summary written to: %s\n', summaryFile);
    disp(summaryTable);
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

        % In R2023b, signal logging properties belong to the output port,
        % not to the connected line handle.
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
            warning('run_mil_baseline:LoggingRestoreFailed', ...
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

function label = localReferenceLabel(reference)
    if reference >= 0
        label = sprintf('plus_%g', reference);
    else
        label = sprintf('minus_%g', abs(reference));
    end
    label = regexprep(label, '[^0-9A-Za-z_-]', '_');
end
