function [scanTable, thresholdTable] = characterize_saturation_threshold(varargin)
%CHARACTERIZE_SATURATION_THRESHOLD Scan bypass step commands near +/-12 V.
%
%   Default scan configuration (all are name-value options):
%     CoarseStartMagnitude_rps = 15
%     CoarseStopMagnitude_rps  = 20
%     CoarseStep_rps           = 0.5
%     FineStep_rps             = 0.05
%     StopTime_s               = 1
%
%   Each direction is scanned at the coarse resolution until the first
%   saturated point is found. The interval between that point and the
%   preceding unsaturated point is then scanned using FineStep_rps.
%   Saturation means controller voltage reaches +/-Vdc within a 1e-9 V
%   numeric tolerance. Cumulative time is the trapezoidal integral of the
%   saturation indicator. No PASS/FAIL decision is made.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'CoarseStartMagnitude_rps', 15, @localPositiveScalar);
    addParameter(parser, 'CoarseStopMagnitude_rps', 20, @localPositiveScalar);
    addParameter(parser, 'CoarseStep_rps', 0.5, @localPositiveScalar);
    addParameter(parser, 'FineStep_rps', 0.05, @localPositiveScalar);
    addParameter(parser, 'StopTime_s', 1, @localPositiveScalar);
    addParameter(parser, 'ResultsDirectory', '', ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    parse(parser, varargin{:});
    options = parser.Results;

    if options.CoarseStopMagnitude_rps <= options.CoarseStartMagnitude_rps
        error('characterize_saturation_threshold:InvalidCoarseRange', ...
            'CoarseStopMagnitude_rps must exceed CoarseStartMagnitude_rps.');
    end
    if options.FineStep_rps >= options.CoarseStep_rps
        error('characterize_saturation_threshold:InvalidFineStep', ...
            'FineStep_rps must be smaller than CoarseStep_rps.');
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
    controllerPath = [modelName, '/PI Speed Controller'];
    portHandles = get_param(controllerPath, 'PortHandles');
    portHandle = portHandles.Outport(1);
    loggingState = struct( ...
        'PortHandle', portHandle, ...
        'DataLogging', get_param(portHandle, 'DataLogging'), ...
        'DataLoggingNameMode', get_param(portHandle, 'DataLoggingNameMode'), ...
        'DataLoggingName', get_param(portHandle, 'DataLoggingName'));
    set_param(portHandle, ...
        'DataLogging', 'on', 'DataLoggingNameMode', 'Custom', ...
        'DataLoggingName', 'pi_controller_output_voltage_v');
    restoreModel = onCleanup(@() localRestoreModel( ...
        modelName, modelWasLoaded, originalDirtyState, loggingState)); %#ok<NASGU>

    pulseGenerator = localFindUniqueBlock(modelName, ...
        'BlockType', 'DiscretePulseGenerator');
    blockPaths = struct( ...
        'PulseGenerator', pulseGenerator, ...
        'ReferenceOffset', [modelName, '/Constant2'], ...
        'ReferenceSwitch', [modelName, '/Manual Switch'], ...
        'ReferenceFilter', [modelName, '/Transfer Fcn1']);

    coarseMagnitudes = localGrid( ...
        options.CoarseStartMagnitude_rps, ...
        options.CoarseStopMagnitude_rps, ...
        options.CoarseStep_rps);
    directions = [1, -1];
    directionNames = ["Positive"; "Negative"];
    scanTable = table();
    thresholdRows = repmat(struct( ...
        'Direction', "", 'DirectionSign', 0, ...
        'LastUnsaturatedMagnitude_rps', NaN, ...
        'FirstSaturatedMagnitude_rps', NaN, ...
        'LastUnsaturatedReference_rps', NaN, ...
        'FirstSaturatedReference_rps', NaN, ...
        'FinalResolution_rps', NaN), numel(directions), 1);

    for directionIndex = 1:numel(directions)
        direction = directions(directionIndex);
        coarseTable = localScanMagnitudes( ...
            coarseMagnitudes, "Coarse", directionNames(directionIndex), ...
            direction, modelName, blockPaths, simulationVariables, ...
            options.StopTime_s, Vdc);

        firstCoarseSaturation = find(coarseTable.SaturationOccurred, 1, 'first');
        fineTable = table();
        if ~isempty(firstCoarseSaturation)
            upperMagnitude = coarseTable.ReferenceMagnitude_rps( ...
                firstCoarseSaturation);
            if firstCoarseSaturation > 1
                lowerMagnitude = coarseTable.ReferenceMagnitude_rps( ...
                    firstCoarseSaturation - 1);
            else
                lowerMagnitude = max(0, upperMagnitude - options.CoarseStep_rps);
            end
            fineStart = lowerMagnitude + options.FineStep_rps;
            fineStop = upperMagnitude - options.FineStep_rps;
            if fineStart <= fineStop + 1e-12
                fineMagnitudes = localGrid( ...
                    fineStart, fineStop, options.FineStep_rps);
                fineTable = localScanMagnitudes( ...
                    fineMagnitudes, "Fine", directionNames(directionIndex), ...
                    direction, modelName, blockPaths, simulationVariables, ...
                    options.StopTime_s, Vdc);
            end
        end

        directionTable = coarseTable;
        if ~isempty(fineTable)
            directionTable = [directionTable; fineTable];
        end
        directionTable = sortrows(directionTable, 'ReferenceMagnitude_rps');
        scanTable = [scanTable; directionTable]; %#ok<AGROW>

        saturatedRows = directionTable.SaturationOccurred;
        if any(saturatedRows)
            firstSaturatedMagnitude = min( ...
                directionTable.ReferenceMagnitude_rps(saturatedRows));
            unsaturatedBelow = directionTable.ReferenceMagnitude_rps( ...
                ~saturatedRows & ...
                directionTable.ReferenceMagnitude_rps < firstSaturatedMagnitude);
            if isempty(unsaturatedBelow)
                lastUnsaturatedMagnitude = NaN;
            else
                lastUnsaturatedMagnitude = max(unsaturatedBelow);
            end
            finalResolution = options.FineStep_rps;
        else
            firstSaturatedMagnitude = NaN;
            lastUnsaturatedMagnitude = max( ...
                directionTable.ReferenceMagnitude_rps);
            finalResolution = options.CoarseStep_rps;
        end

        thresholdRows(directionIndex).Direction = ...
            directionNames(directionIndex);
        thresholdRows(directionIndex).DirectionSign = direction;
        thresholdRows(directionIndex).LastUnsaturatedMagnitude_rps = ...
            lastUnsaturatedMagnitude;
        thresholdRows(directionIndex).FirstSaturatedMagnitude_rps = ...
            firstSaturatedMagnitude;
        thresholdRows(directionIndex).LastUnsaturatedReference_rps = ...
            direction * lastUnsaturatedMagnitude;
        thresholdRows(directionIndex).FirstSaturatedReference_rps = ...
            direction * firstSaturatedMagnitude;
        thresholdRows(directionIndex).FinalResolution_rps = finalResolution;
    end

    thresholdTable = struct2table(thresholdRows);
    scanFile = fullfile(resultsDirectory, 'saturation_scan_summary.csv');
    thresholdFile = fullfile( ...
        resultsDirectory, 'saturation_threshold_intervals.csv');
    writetable(scanTable, scanFile);
    writetable(thresholdTable, thresholdFile);
    fprintf('Saturation scan written to: %s\n', scanFile);
    fprintf('Saturation intervals written to: %s\n', thresholdFile);
    disp(thresholdTable);
end

function scanTable = localScanMagnitudes( ...
        magnitudes, scanStage, directionName, direction, modelName, ...
        blockPaths, simulationVariables, stopTime_s, Vdc)
    numberOfPoints = numel(magnitudes);
    scanStages = repmat(string(scanStage), numberOfPoints, 1);
    directionNames = repmat(string(directionName), numberOfPoints, 1);
    directionSigns = repmat(direction, numberOfPoints, 1);
    references = direction * magnitudes(:);
    peakControllerVoltage = zeros(numberOfPoints, 1);
    positiveSaturationOccurred = false(numberOfPoints, 1);
    negativeSaturationOccurred = false(numberOfPoints, 1);
    saturationOccurred = false(numberOfPoints, 1);
    saturationCumulativeTime = zeros(numberOfPoints, 1);
    saturationTolerance_v = max(1e-9, 100 * eps(Vdc));

    for pointIndex = 1:numberOfPoints
        reference = references(pointIndex);
        simulationInput = Simulink.SimulationInput(modelName);
        variableNames = fieldnames(simulationVariables);
        for variableIndex = 1:numel(variableNames)
            variableName = variableNames{variableIndex};
            simulationInput = simulationInput.setVariable( ...
                variableName, simulationVariables.(variableName));
        end
        simulationInput = simulationInput.setBlockParameter( ...
            blockPaths.PulseGenerator, 'Amplitude', '0');
        simulationInput = simulationInput.setBlockParameter( ...
            blockPaths.ReferenceOffset, ...
            'Value', sprintf('%.17g', -reference / 15));
        simulationInput = simulationInput.setBlockParameter( ...
            blockPaths.ReferenceSwitch, 'CurrentSetting', '1');
        simulationInput = simulationInput.setBlockParameter( ...
            blockPaths.ReferenceFilter, 'Numerator', '[1]');
        simulationInput = simulationInput.setBlockParameter( ...
            blockPaths.ReferenceFilter, 'Denominator', '[1]');
        simulationInput = simulationInput.setModelParameter( ...
            'StopTime', sprintf('%.17g', stopTime_s), ...
            'SignalLogging', 'on', ...
            'SignalLoggingName', 'logsout', ...
            'SignalLoggingSaveFormat', 'Dataset', ...
            'ReturnWorkspaceOutputs', 'on');

        simulationOutput = sim(simulationInput);
        loggedSignals = simulationOutput.get('logsout');
        voltageSignal = localGetLoggedSignal( ...
            loggedSignals, 'pi_controller_output_voltage_v');
        time = voltageSignal.Time;
        voltage = voltageSignal.Data;

        if direction > 0
            peakControllerVoltage(pointIndex) = max(voltage, [], 'omitnan');
        else
            peakControllerVoltage(pointIndex) = min(voltage, [], 'omitnan');
        end
        positiveSaturation = voltage >= Vdc - saturationTolerance_v;
        negativeSaturation = voltage <= -Vdc + saturationTolerance_v;
        saturationIndicator = positiveSaturation | negativeSaturation;
        positiveSaturationOccurred(pointIndex) = any(positiveSaturation);
        negativeSaturationOccurred(pointIndex) = any(negativeSaturation);
        saturationOccurred(pointIndex) = any(saturationIndicator);
        saturationCumulativeTime(pointIndex) = trapz( ...
            time, double(saturationIndicator));
    end

    scanTable = table( ...
        scanStages, directionNames, directionSigns, magnitudes(:), references, ...
        peakControllerVoltage, saturationOccurred, ...
        positiveSaturationOccurred, negativeSaturationOccurred, ...
        saturationCumulativeTime, ...
        'VariableNames', { ...
            'ScanStage', 'Direction', 'DirectionSign', ...
            'ReferenceMagnitude_rps', 'Reference_rps', ...
            'PeakControllerVoltage_V', 'SaturationOccurred', ...
            'Positive12VSaturationOccurred', ...
            'Negative12VSaturationOccurred', ...
            'SaturationCumulativeTime_s'});
end

function values = localGrid(firstValue, lastValue, step)
    count = floor((lastValue - firstValue) / step + 1e-12);
    values = firstValue + (0:count) * step;
    if values(end) < lastValue - 1e-12
        values(end + 1) = lastValue;
    end
end

function valid = localPositiveScalar(value)
    valid = isnumeric(value) && isscalar(value) && isfinite(value) && value > 0;
end

function localRestoreModel(modelName, modelWasLoaded, dirtyState, loggingState)
    if ~bdIsLoaded(modelName)
        return;
    end
    set_param(loggingState.PortHandle, ...
        'DataLogging', loggingState.DataLogging, ...
        'DataLoggingNameMode', loggingState.DataLoggingNameMode, ...
        'DataLoggingName', loggingState.DataLoggingName);
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
