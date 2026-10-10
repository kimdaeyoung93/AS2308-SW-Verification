function [scanTable, firstSaturationTable] = ...
        characterize_voltage_saturation(varargin)
%CHARACTERIZE_VOLTAGE_SATURATION Find nominal-range saturation stimuli.
%
%   [SCANTABLE, FIRSTSATURATIONTABLE] = CHARACTERIZE_VOLTAGE_SATURATION()
%   sweeps positive and negative SpeedRef values from 15 to 19.75 rps in
%   0.25 rps increments using AS2308_MIL_Baseline_v2.
%
%   Name-value options:
%     'Magnitudes_rps'  Positive sweep magnitudes below 20 rps
%                       (default: 15:0.25:19.75)
%     'StopTime_s'      Simulation stop time (default: 1)
%
%   raw_pi_output is used only as evidence that the PI output has exceeded
%   the actuator limit and invoked saturation. REQ-VOLT-001 PASS/FAIL uses
%   only Vcmd through evaluate_voltage_limit.
%
%   This is healthy-baseline characterization for selecting MTC-001 input
%   conditions. It does not define a new product requirement or threshold.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'Magnitudes_rps', 15:0.25:19.75, ...
        @(x) isnumeric(x) && isreal(x) && isvector(x) && ~isempty(x) && ...
        all(isfinite(x)) && all(x > 0) && all(x < 20));
    addParameter(parser, 'StopTime_s', 1, ...
        @(x) isnumeric(x) && isreal(x) && isscalar(x) && ...
        isfinite(x) && x > 0);
    parse(parser, varargin{:});
    options = parser.Results;

    magnitudes_rps = unique(sort(double(options.Magnitudes_rps(:))));
    stopTime_s = double(options.StopTime_s);
    voltageLimit_v = 12;

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
    assert(isfile(fullfile(oracleDirectory, 'evaluate_voltage_limit.m')), ...
        'Voltage Limit Oracle not found in: %s', oracleDirectory);

    addpath(oracleDirectory);
    run(parameterScript);
    simulationVariables = struct( ...
        'ts', ts, 'Vdc', Vdc, 'Kps', Kps, 'Kis', Kis, 'Kas', Kas);

    modelWasLoaded = bdIsLoaded(modelName);
    load_system(modelFile);
    closeModel = onCleanup(@() localCloseModel(modelName, modelWasLoaded)); %#ok<NASGU>

    references_rps = [magnitudes_rps; -magnitudes_rps];
    numberOfRuns = numel(references_rps);

    direction = strings(numberOfRuns, 1);
    speedReference_rps = zeros(numberOfRuns, 1);
    maxRawPiOutput_v = zeros(numberOfRuns, 1);
    minRawPiOutput_v = zeros(numberOfRuns, 1);
    maxVcmd_v = zeros(numberOfRuns, 1);
    minVcmd_v = zeros(numberOfRuns, 1);
    positiveRawLimitExceeded = false(numberOfRuns, 1);
    negativeRawLimitExceeded = false(numberOfRuns, 1);
    saturationOccurred = false(numberOfRuns, 1);
    vcmdClampedAtPositiveLimit = false(numberOfRuns, 1);
    vcmdClampedAtNegativeLimit = false(numberOfRuns, 1);
    voltageLimitOraclePass = false(numberOfRuns, 1);

    fprintf('\nVoltage saturation characterization\n');
    fprintf('Model: %s\n', modelName);
    fprintf('Nominal sweep: %.4g to %.4g rps, both directions\n\n', ...
        magnitudes_rps(1), magnitudes_rps(end));

    for runIndex = 1:numberOfRuns
        reference_rps = references_rps(runIndex);
        speedReference_rps(runIndex) = reference_rps;
        if reference_rps > 0
            direction(runIndex) = "Positive";
        else
            direction(runIndex) = "Negative";
        end

        simulationInput = Simulink.SimulationInput(modelName);
        variableNames = fieldnames(simulationVariables);
        for variableIndex = 1:numel(variableNames)
            variableName = variableNames{variableIndex};
            simulationInput = simulationInput.setVariable( ...
                variableName, simulationVariables.(variableName));
        end
        simulationInput = simulationInput.setVariable( ...
            'SpeedRef_cmd', reference_rps);
        simulationInput = simulationInput.setModelParameter( ...
            'StopTime', sprintf('%.17g', stopTime_s), ...
            'SignalLogging', 'on', ...
            'SignalLoggingName', 'logsout', ...
            'SignalLoggingSaveFormat', 'Dataset', ...
            'ReturnWorkspaceOutputs', 'on');

        simulationOutput = sim(simulationInput);
        loggedSignals = simulationOutput.get('logsout');
        rawPiSignal = localGetLoggedSignal(loggedSignals, 'raw_pi_output');
        vcmdSignal = localGetLoggedSignal(loggedSignals, 'Vcmd');

        rawPiOutput = double(squeeze(rawPiSignal.Data));
        rawPiOutput = rawPiOutput(:);
        vcmdTime = double(vcmdSignal.Time(:));
        vcmd = double(squeeze(vcmdSignal.Data));
        vcmd = vcmd(:);

        maxRawPiOutput_v(runIndex) = max(rawPiOutput);
        minRawPiOutput_v(runIndex) = min(rawPiOutput);
        positiveRawLimitExceeded(runIndex) = ...
            maxRawPiOutput_v(runIndex) > voltageLimit_v;
        negativeRawLimitExceeded(runIndex) = ...
            minRawPiOutput_v(runIndex) < -voltageLimit_v;
        saturationOccurred(runIndex) = ...
            positiveRawLimitExceeded(runIndex) || ...
            negativeRawLimitExceeded(runIndex);

        oracleResult = evaluate_voltage_limit( ...
            vcmdTime, vcmd, voltageLimit_v);
        maxVcmd_v(runIndex) = oracleResult.max_vcmd_v;
        minVcmd_v(runIndex) = oracleResult.min_vcmd_v;
        voltageLimitOraclePass(runIndex) = oracleResult.pass;
        vcmdClampedAtPositiveLimit(runIndex) = ...
            oracleResult.max_vcmd_v == oracleResult.upper_limit_v;
        vcmdClampedAtNegativeLimit(runIndex) = ...
            oracleResult.min_vcmd_v == oracleResult.lower_limit_v;

        fprintf(['%+6.2f rps | raw PI [%+10.6f, %+10.6f] V | ', ...
            'Vcmd [%+10.6f, %+10.6f] V | saturation %d | oracle %s\n'], ...
            reference_rps, minRawPiOutput_v(runIndex), ...
            maxRawPiOutput_v(runIndex), minVcmd_v(runIndex), ...
            maxVcmd_v(runIndex), saturationOccurred(runIndex), ...
            localPassFail(voltageLimitOraclePass(runIndex)));
    end

    scanTable = table( ...
        direction, speedReference_rps, maxRawPiOutput_v, minRawPiOutput_v, ...
        maxVcmd_v, minVcmd_v, positiveRawLimitExceeded, ...
        negativeRawLimitExceeded, saturationOccurred, ...
        vcmdClampedAtPositiveLimit, vcmdClampedAtNegativeLimit, ...
        voltageLimitOraclePass, ...
        'VariableNames', { ...
        'Direction', 'SpeedRef_rps', 'MaxRawPiOutput_v', ...
        'MinRawPiOutput_v', 'MaxVcmd_v', 'MinVcmd_v', ...
        'PositiveRawLimitExceeded', 'NegativeRawLimitExceeded', ...
        'SaturationOccurred', 'VcmdClampedAtPositiveLimit', ...
        'VcmdClampedAtNegativeLimit', 'VoltageLimitOraclePass'});

    firstSaturationTable = localFirstSaturationTable( ...
        scanTable, voltageLimit_v);

    fprintf('\nFirst raw PI limit exceedance in each direction:\n');
    disp(firstSaturationTable);
    fprintf(['NOTE: These values characterize healthy-baseline MTC-001 ', ...
        'stimuli; they are not new product requirements.\n']);
end

function signal = localGetLoggedSignal(loggedSignals, signalName)
    signalElement = loggedSignals.get(signalName);
    if isempty(signalElement)
        error('characterize_voltage_saturation:MissingSignal', ...
            'Logged signal "%s" was not found.', signalName);
    end
    signal = signalElement.Values;
end

function firstSaturationTable = localFirstSaturationTable(scanTable, limit_v)
    directions = ["Positive"; "Negative"];
    firstSpeedReference_rps = NaN(2, 1);
    rawPiExtreme_v = NaN(2, 1);
    vcmdExtreme_v = NaN(2, 1);
    vcmdClampedAtLimit = false(2, 1);
    voltageLimitOraclePass = false(2, 1);

    positiveRows = find( ...
        scanTable.Direction == "Positive" & ...
        scanTable.MaxRawPiOutput_v > limit_v, 1, 'first');
    if ~isempty(positiveRows)
        firstSpeedReference_rps(1) = scanTable.SpeedRef_rps(positiveRows);
        rawPiExtreme_v(1) = scanTable.MaxRawPiOutput_v(positiveRows);
        vcmdExtreme_v(1) = scanTable.MaxVcmd_v(positiveRows);
        vcmdClampedAtLimit(1) = ...
            scanTable.VcmdClampedAtPositiveLimit(positiveRows);
        voltageLimitOraclePass(1) = ...
            scanTable.VoltageLimitOraclePass(positiveRows);
    end

    negativeRows = find( ...
        scanTable.Direction == "Negative" & ...
        scanTable.MinRawPiOutput_v < -limit_v, 1, 'first');
    if ~isempty(negativeRows)
        firstSpeedReference_rps(2) = scanTable.SpeedRef_rps(negativeRows);
        rawPiExtreme_v(2) = scanTable.MinRawPiOutput_v(negativeRows);
        vcmdExtreme_v(2) = scanTable.MinVcmd_v(negativeRows);
        vcmdClampedAtLimit(2) = ...
            scanTable.VcmdClampedAtNegativeLimit(negativeRows);
        voltageLimitOraclePass(2) = ...
            scanTable.VoltageLimitOraclePass(negativeRows);
    end

    firstSaturationTable = table( ...
        directions, firstSpeedReference_rps, rawPiExtreme_v, ...
        vcmdExtreme_v, vcmdClampedAtLimit, voltageLimitOraclePass, ...
        'VariableNames', { ...
        'Direction', 'FirstSpeedRef_rps', 'RawPiExtreme_v', ...
        'VcmdExtreme_v', 'VcmdClampedAtLimit', ...
        'VoltageLimitOraclePass'});
end

function text = localPassFail(pass)
    if pass
        text = 'PASS';
    else
        text = 'FAIL';
    end
end

function localCloseModel(modelName, modelWasLoaded)
    if ~modelWasLoaded && bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end
