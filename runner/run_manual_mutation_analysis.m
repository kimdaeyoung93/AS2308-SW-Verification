function [executionResults, killMatrix, summary, perMutant, detailData] = ...
        run_manual_mutation_analysis()
%RUN_MANUAL_MUTATION_ANALYSIS Execute the frozen primary mutation set.
%
%   Runs the frozen Manual Dynamic MIL Test Suite v1.0 first without a
%   mutation and requires all nine top-level executions to PASS. It then
%   applies each mutation from mutations/01_Mutation_Set.csv by using only
%   Simulink.SimulationInput run-time overrides.
%
%   No static configuration check kills a mutant. A valid mutant is killed
%   only when an execution that passed on the baseline fails through its
%   existing Oracle, a simulation error, or non-finite simulation output.
%   The model file is never saved by this runner.

    modelName = 'AS2308_MIL_Baseline_v3';
    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    modelDirectory = fullfile(repositoryRoot, 'model');
    oracleDirectory = fullfile(runnerDirectory, 'oracles');
    resultsDirectory = fullfile(repositoryRoot, 'results');
    mutationFile = fullfile( ...
        repositoryRoot, 'mutations', '01_Mutation_Set.csv');
    modelFile = fullfile(modelDirectory, [modelName, '.slx']);
    parameterScript = fullfile( ...
        modelDirectory, 'AS2308_calculate_pi_control_cc.m');

    assert(isfile(modelFile), 'Model file not found: %s', modelFile);
    assert(isfile(mutationFile), ...
        'Frozen mutation definition not found: %s', mutationFile);
    assert(isfile(parameterScript), ...
        'Parameter script not found: %s', parameterScript);
    assert(isfile(fullfile(oracleDirectory, 'evaluate_voltage_limit.m')), ...
        'Voltage Oracle not found in: %s', oracleDirectory);
    assert(isfile(fullfile(oracleDirectory, 'evaluate_tracking.m')), ...
        'Tracking Oracle not found in: %s', oracleDirectory);
    assert(isfile(fullfile(oracleDirectory, 'evaluate_direction.m')), ...
        'Direction Oracle not found in: %s', oracleDirectory);

    addpath(oracleDirectory);
    run(parameterScript);
    baselineKis = Kis;
    simulationVariables = struct( ...
        'ts', ts, 'Vdc', Vdc, 'Kps', Kps, 'Kis', Kis, 'Kas', Kas, ...
        'SpeedRef_cmd', 0);

    mutationImportOptions = detectImportOptions(mutationFile, ...
        'TextType', 'string', 'VariableNamingRule', 'preserve');
    mutationImportOptions = setvartype( ...
        mutationImportOptions, mutationImportOptions.VariableNames, 'string');
    mutationDefinitions = readtable(mutationFile, mutationImportOptions);
    localValidateMutationFile(mutationDefinitions);

    modelWasLoaded = bdIsLoaded(modelName);
    load_system(modelFile);
    closeModel = onCleanup( ...
        @() localCloseModel(modelName, modelWasLoaded));

    assert(strcmp(get_param(modelName, 'SolverType'), 'Fixed-step'), ...
        'Stored model SolverType must be Fixed-step.');
    assert(strcmp(get_param(modelName, 'Solver'), 'ode4'), ...
        'Stored model Solver must be ode4.');
    assert(strcmp(get_param(modelName, 'FixedStep'), 'ts'), ...
        'Stored model FixedStep must be ts.');
    assert(ts == 0.0004, 'Expected ts = 0.0004 s.');

    modelStateBefore = dir(modelFile);
    paths = localResolveModelPaths(modelName);
    executionDefinitions = localExecutionDefinitions();

    fprintf('\nManual Dynamic MIL Suite v1.0 Mutation Analysis\n');
    fprintf('Model: %s\n', modelName);
    fprintf('Mutation set: %s\n', mutationFile);
    fprintf('Stored solver: Fixed-step / ode4 / ts (ts = %.7g s)\n\n', ts);

    %% Baseline consistency check through the mutation-analysis path
    fprintf('Baseline consistency check (no mutation)\n');
    baselineResults = localRunSuiteVariant( ...
        modelName, simulationVariables, baselineKis, paths, ...
        executionDefinitions, "BASELINE");
    baselinePassCount = sum(baselineResults.Pass);
    fprintf('Baseline result: %d/9 PASS\n\n', baselinePassCount);
    if height(baselineResults) ~= 9 || baselinePassCount ~= 9
        failedRows = baselineResults(~baselineResults.Pass, :);
        disp(failedRows);
        error('run_manual_mutation_analysis:BaselineConsistencyFailed', ...
            ['Baseline consistency check failed (%d/9 PASS). ', ...
             'Mutation execution was not started.'], baselinePassCount);
    end

    %% Execute the six frozen primary mutants
    mutantCount = height(mutationDefinitions);
    executionCount = height(executionDefinitions);
    mutantResultCells = cell(mutantCount, 1);
    applicability = false(mutantCount, 1);
    invalidReason = strings(mutantCount, 1);

    for mutantIndex = 1:mutantCount
        mutation = mutationDefinitions(mutantIndex, :);
        mutationID = mutation.MutationID;
        fprintf('Mutation %d/%d: %s (%s)\n', ...
            mutantIndex, mutantCount, mutationID, mutation.MutationName);

        [applicability(mutantIndex), invalidReason(mutantIndex)] = ...
            localValidateMutationApplicability( ...
            modelName, baselineKis, Vdc, mutation);

        if ~applicability(mutantIndex)
            fprintf('  INVALID: %s\n\n', invalidReason(mutantIndex));
            mutantResultCells{mutantIndex} = localInvalidExecutionRows( ...
                executionDefinitions, invalidReason(mutantIndex));
            continue;
        end

        mutantResultCells{mutantIndex} = localRunSuiteVariant( ...
            modelName, simulationVariables, baselineKis, paths, ...
            executionDefinitions, mutationID);
        killedCount = sum(~mutantResultCells{mutantIndex}.Pass);
        fprintf('  killing executions: %d/9\n\n', killedCount);
    end

    %% Long-form execution results
    totalRows = mutantCount * executionCount;
    MutationID = strings(totalRows, 1);
    TestCaseID = strings(totalRows, 1);
    IterationID = strings(totalRows, 1);
    RequirementID = strings(totalRows, 1);
    BaselineResult = repmat("PASS", totalRows, 1);
    MutantResult = strings(totalRows, 1);
    KilledByExecution = false(totalRows, 1);
    KillReason = strings(totalRows, 1);
    KeyMetric = strings(totalRows, 1);
    KeyMetricValue = NaN(totalRows, 1);
    ErrorMessage = strings(totalRows, 1);

    outputRow = 0;
    for mutantIndex = 1:mutantCount
        mutationID = mutationDefinitions.MutationID(mutantIndex);
        results = mutantResultCells{mutantIndex};
        for executionIndex = 1:executionCount
            outputRow = outputRow + 1;
            MutationID(outputRow) = mutationID;
            TestCaseID(outputRow) = ...
                executionDefinitions.TestCaseID(executionIndex);
            IterationID(outputRow) = ...
                executionDefinitions.IterationID(executionIndex);
            RequirementID(outputRow) = ...
                executionDefinitions.RequirementID(executionIndex);
            if applicability(mutantIndex)
                if results.Pass(executionIndex)
                    MutantResult(outputRow) = "PASS";
                else
                    MutantResult(outputRow) = "FAIL";
                    KilledByExecution(outputRow) = true;
                end
            else
                MutantResult(outputRow) = "INVALID";
            end
            KillReason(outputRow) = results.KillReason(executionIndex);
            KeyMetric(outputRow) = results.KeyMetric(executionIndex);
            KeyMetricValue(outputRow) = ...
                results.KeyMetricValue(executionIndex);
            ErrorMessage(outputRow) = results.ErrorMessage(executionIndex);
        end
    end

    executionResults = table( ...
        MutationID, TestCaseID, IterationID, RequirementID, ...
        BaselineResult, MutantResult, KilledByExecution, KillReason, ...
        KeyMetric, KeyMetricValue, ErrorMessage);

    %% Kill matrix and per-mutant summary
    matrixValues = strings(mutantCount, executionCount);
    mutantStatus = strings(mutantCount, 1);
    killedByCount = zeros(mutantCount, 1);
    firstKillingTest = strings(mutantCount, 1);
    aggregateKillReason = strings(mutantCount, 1);
    detectedRequirementTests = strings(mutantCount, 1);

    for mutantIndex = 1:mutantCount
        rowStart = (mutantIndex - 1) * executionCount + 1;
        rowEnd = rowStart + executionCount - 1;
        rows = executionResults(rowStart:rowEnd, :);

        if ~applicability(mutantIndex)
            matrixValues(mutantIndex, :) = "INVALID";
            mutantStatus(mutantIndex) = "INVALID";
            aggregateKillReason(mutantIndex) = invalidReason(mutantIndex);
            continue;
        end

        matrixValues(mutantIndex, :) = "PASS";
        matrixValues(mutantIndex, rows.KilledByExecution) = "KILL";
        killedByCount(mutantIndex) = sum(rows.KilledByExecution);
        if killedByCount(mutantIndex) > 0
            mutantStatus(mutantIndex) = "KILLED";
            firstIndex = find(rows.KilledByExecution, 1, 'first');
            firstKillingTest(mutantIndex) = ...
                rows.TestCaseID(firstIndex) + "/" + rows.IterationID(firstIndex);
            aggregateKillReason(mutantIndex) = strjoin( ...
                unique(rows.KillReason(rows.KilledByExecution), 'stable'), ...
                "; ");
            detectedRequirementTests(mutantIndex) = strjoin( ...
                unique(rows.RequirementID(rows.KilledByExecution), 'stable'), ...
                "; ");
        else
            mutantStatus(mutantIndex) = "SURVIVED - requires review";
            aggregateKillReason(mutantIndex) = "None";
            detectedRequirementTests(mutantIndex) = "None";
        end
    end

    matrixVariableNames = [ ...
        "MTC001_IT001", "MTC001_IT002", ...
        "MTC002_IT001", "MTC002_IT002", ...
        "MTC003_IT001", "MTC003_IT002", ...
        "MTC004_IT001", "MTC004_IT002", "MTC005_IT001"];
    killMatrix = array2table(matrixValues, ...
        'VariableNames', cellstr(matrixVariableNames));
    killMatrix = addvars(killMatrix, mutationDefinitions.MutationID, ...
        'Before', 1, 'NewVariableNames', 'MutationID');

    perMutant = table( ...
        mutationDefinitions.MutationID, mutationDefinitions.MutationName, ...
        mutantStatus, killedByCount, firstKillingTest, ...
        aggregateKillReason, detectedRequirementTests, ...
        'VariableNames', {'MutationID', 'MutationName', 'Status', ...
        'KilledByCount', 'FirstKillingTest', 'KillReason', ...
        'DetectedRequirementTests'});

    totalDefinedMutants = mutantCount;
    validMutants = sum(applicability);
    killedMutants = sum(mutantStatus == "KILLED");
    survivedMutants = sum(mutantStatus == "SURVIVED - requires review");
    invalidMutants = sum(mutantStatus == "INVALID");
    if validMutants == 0
        mutationScorePercent = NaN;
    else
        mutationScorePercent = 100 * killedMutants / validMutants;
    end
    summary = table( ...
        totalDefinedMutants, validMutants, killedMutants, ...
        survivedMutants, invalidMutants, mutationScorePercent, ...
        'VariableNames', {'total_defined_mutants', 'valid_mutants', ...
        'killed_mutants', 'survived_mutants', 'invalid_mutants', ...
        'mutation_score_percent'});

    if ~isfolder(resultsDirectory)
        mkdir(resultsDirectory);
    end
    executionCsv = fullfile( ...
        resultsDirectory, 'manual_mutation_execution_results.csv');
    matrixCsv = fullfile( ...
        resultsDirectory, 'manual_mutation_kill_matrix.csv');
    summaryCsv = fullfile( ...
        resultsDirectory, 'manual_mutation_summary.csv');
    perMutantCsv = fullfile( ...
        resultsDirectory, 'manual_mutation_per_mutant.csv');
    writetable(executionResults, executionCsv);
    writetable(killMatrix, matrixCsv);
    writetable(summary, summaryCsv);
    writetable(perMutant, perMutantCsv);

    detailData = struct( ...
        'baseline_results', baselineResults, ...
        'mutant_execution_results', {mutantResultCells}, ...
        'execution_definitions', executionDefinitions, ...
        'mutation_definitions', mutationDefinitions, ...
        'baseline_consistency_pass', true, ...
        'execution_results_csv', string(executionCsv), ...
        'kill_matrix_csv', string(matrixCsv), ...
        'summary_csv', string(summaryCsv), ...
        'per_mutant_csv', string(perMutantCsv));

    modelStateAfter = dir(modelFile);
    assert(modelStateBefore.bytes == modelStateAfter.bytes && ...
        modelStateBefore.datenum == modelStateAfter.datenum, ...
        'The on-disk model file changed during mutation analysis.');

    fprintf('\nPer-mutant result:\n');
    disp(perMutant);
    fprintf('Kill matrix:\n');
    disp(killMatrix);
    fprintf(['Mutation score: %d killed / %d valid = %.12g%% ', ...
        '(%d invalid)\n'], killedMutants, validMutants, ...
        mutationScorePercent, invalidMutants);
    clear closeModel;
end

function definitions = localExecutionDefinitions()
    TestCaseID = [ ...
        "MTC-001"; "MTC-001"; "MTC-002"; "MTC-002"; ...
        "MTC-003"; "MTC-003"; "MTC-004"; "MTC-004"; "MTC-005"];
    IterationID = [ ...
        "IT-001"; "IT-002"; "IT-001"; "IT-002"; ...
        "IT-001"; "IT-002"; "IT-001"; "IT-002"; "IT-001"];
    RequirementID = [ ...
        "REQ-VOLT-001"; "REQ-VOLT-001"; ...
        "REQ-TRK-001"; "REQ-TRK-001"; ...
        "REQ-DIR-001"; "REQ-DIR-001"; ...
        "REQ-REV-001"; "REQ-REV-001"; "REQ-REV-001"];
    Kind = [ ...
        "VoltagePositive"; "VoltageNegative"; ...
        "TrackingPositive"; "TrackingNegative"; ...
        "DirectionPositive"; "DirectionNegative"; ...
        "SinglePositiveToNegative"; "SingleNegativeToPositive"; ...
        "RepeatedReversal"];
    definitions = table(TestCaseID, IterationID, RequirementID, Kind);
end

function results = localRunSuiteVariant( ...
        modelName, simulationVariables, baselineKis, paths, ...
        definitions, mutationID)
    executionCount = height(definitions);
    Pass = false(executionCount, 1);
    KillReason = strings(executionCount, 1);
    KeyMetric = strings(executionCount, 1);
    KeyMetricValue = NaN(executionCount, 1);
    ErrorMessage = strings(executionCount, 1);

    for executionIndex = 1:executionCount
        definition = definitions(executionIndex, :);
        fprintf('  %s/%s ... ', ...
            definition.TestCaseID, definition.IterationID);
        result = localRunExecution( ...
            modelName, simulationVariables, baselineKis, paths, ...
            definition.Kind, mutationID);
        Pass(executionIndex) = result.pass;
        KillReason(executionIndex) = result.killReason;
        KeyMetric(executionIndex) = result.keyMetric;
        KeyMetricValue(executionIndex) = result.keyMetricValue;
        ErrorMessage(executionIndex) = result.errorMessage;
        fprintf('%s', localPassFail(result.pass));
        if strlength(result.killReason) > 0
            fprintf(' (%s)', result.killReason);
        end
        fprintf('\n');
    end

    results = [definitions, table( ...
        Pass, KillReason, KeyMetric, KeyMetricValue, ErrorMessage)];
end

function result = localRunExecution( ...
        modelName, simulationVariables, baselineKis, paths, kind, mutationID)
    result = struct( ...
        'pass', false, 'killReason', "", 'keyMetric', "", ...
        'keyMetricValue', NaN, 'errorMessage', "");

    try
        switch kind
            case "VoltagePositive"
                simulationInput = localConstantInput( ...
                    modelName, simulationVariables, 16.75, mutationID, ...
                    baselineKis);
            case "VoltageNegative"
                simulationInput = localConstantInput( ...
                    modelName, simulationVariables, -16.75, mutationID, ...
                    baselineKis);
            case "TrackingPositive"
                simulationInput = localConstantInput( ...
                    modelName, simulationVariables, 2, mutationID, ...
                    baselineKis);
            case "TrackingNegative"
                simulationInput = localConstantInput( ...
                    modelName, simulationVariables, -2, mutationID, ...
                    baselineKis);
            case "DirectionPositive"
                simulationInput = localConstantInput( ...
                    modelName, simulationVariables, 15, mutationID, ...
                    baselineKis);
            case "DirectionNegative"
                simulationInput = localConstantInput( ...
                    modelName, simulationVariables, -15, mutationID, ...
                    baselineKis);
            case "SinglePositiveToNegative"
                simulationInput = localSingleReversalInput( ...
                    modelName, simulationVariables, paths, 1, ...
                    mutationID, baselineKis);
            case "SingleNegativeToPositive"
                simulationInput = localSingleReversalInput( ...
                    modelName, simulationVariables, paths, -1, ...
                    mutationID, baselineKis);
            case "RepeatedReversal"
                simulationInput = localRepeatedReversalInput( ...
                    modelName, simulationVariables, paths, mutationID, ...
                    baselineKis);
            otherwise
                error('run_manual_mutation_analysis:UnknownExecution', ...
                    'Unknown execution kind: %s', kind);
        end
        simulationOutput = sim(simulationInput);
    catch exception
        result.killReason = "SimulationError";
        result.errorMessage = string(exception.message);
        return;
    end

    try
        signals = localExtractSignals(simulationOutput);
    catch exception
        result.killReason = "SimulationError";
        result.errorMessage = string(exception.message);
        return;
    end

    if localHasNonFinite(signals)
        result.killReason = "NonFinite";
        result.errorMessage = "One or more logged signals contain NaN or Inf.";
        return;
    end

    try
        switch kind
            case "VoltagePositive"
                oracle = evaluate_voltage_limit(signals.time, signals.Vcmd);
                result.pass = oracle.pass;
                result.keyMetric = "max_vcmd_v";
                result.keyMetricValue = oracle.max_vcmd_v;
            case "VoltageNegative"
                oracle = evaluate_voltage_limit(signals.time, signals.Vcmd);
                result.pass = oracle.pass;
                result.keyMetric = "min_vcmd_v";
                result.keyMetricValue = oracle.min_vcmd_v;
            case {"TrackingPositive", "TrackingNegative"}
                oracle = evaluate_tracking( ...
                    signals.time, signals.reference, signals.motorspeed);
                result.pass = oracle.pass;
                result.keyMetric = "max_abs_error_rps";
                result.keyMetricValue = oracle.max_abs_error_rps;
            case {"DirectionPositive", "DirectionNegative"}
                oracle = evaluate_direction( ...
                    signals.time, signals.reference, signals.motorspeed);
                result.pass = oracle.pass;
                result.keyMetric = "direction_mismatch_sample_count";
                result.keyMetricValue = oracle.mismatch_sample_count;
            case {"SinglePositiveToNegative", ...
                    "SingleNegativeToPositive"}
                directionResult = evaluate_direction( ...
                    signals.time, signals.reference, signals.motorspeed);
                trackingResult = evaluate_tracking( ...
                    signals.time, signals.reference, signals.motorspeed);
                result.pass = directionResult.pass && trackingResult.pass;
                result.keyMetric = "tracking_max_abs_error_rps";
                result.keyMetricValue = trackingResult.max_abs_error_rps;
            case "RepeatedReversal"
                [result.pass, passedSegments] = ...
                    localEvaluateRepeatedReversal(signals);
                result.keyMetric = "passed_segment_count";
                result.keyMetricValue = passedSegments;
        end
    catch exception
        result.pass = false;
        result.killReason = "OracleError";
        result.errorMessage = string(exception.message);
        return;
    end

    if ~result.pass
        result.killReason = "OracleFail";
    end
end

function simulationInput = localConstantInput( ...
        modelName, variables, reference_rps, mutationID, baselineKis)
    simulationInput = localBaseInput( ...
        modelName, variables, 1, mutationID, baselineKis);
    simulationInput = simulationInput.setVariable( ...
        'SpeedRef_cmd', reference_rps);
end

function simulationInput = localSingleReversalInput( ...
        modelName, variables, paths, initialDirection, ...
        mutationID, baselineKis)
    stopTime_s = 4;
    switchingTime_s = 2;
    pulsePeriod_s = 2 * stopTime_s;
    pulseWidth_pct = 100 * switchingTime_s / pulsePeriod_s;
    simulationInput = localBaseInput( ...
        modelName, variables, stopTime_s, mutationID, baselineKis);
    simulationInput = simulationInput.setBlockParameter( ...
        paths.pulseGenerator, 'Amplitude', ...
        sprintf('%g', 2 * initialDirection));
    simulationInput = simulationInput.setBlockParameter( ...
        paths.pulseGenerator, 'Period', sprintf('%.17g', pulsePeriod_s));
    simulationInput = simulationInput.setBlockParameter( ...
        paths.pulseGenerator, 'PulseWidth', ...
        sprintf('%.17g', pulseWidth_pct));
    simulationInput = simulationInput.setBlockParameter( ...
        paths.pulseGenerator, 'PhaseDelay', '0');
    simulationInput = simulationInput.setBlockParameter( ...
        paths.referenceOffset, 'Value', sprintf('%g', initialDirection));
    simulationInput = simulationInput.setBlockParameter( ...
        paths.referenceSwitch, 'CurrentSetting', '1');
end

function simulationInput = localRepeatedReversalInput( ...
        modelName, variables, paths, mutationID, baselineKis)
    % Plateau duration (2 s) and repeat count (3) are the existing MTC-005
    % execution parameters, not new product criteria.
    simulationInput = localBaseInput( ...
        modelName, variables, 12, mutationID, baselineKis);
    simulationInput = simulationInput.setBlockParameter( ...
        paths.pulseGenerator, 'Amplitude', '2');
    simulationInput = simulationInput.setBlockParameter( ...
        paths.pulseGenerator, 'Period', '4');
    simulationInput = simulationInput.setBlockParameter( ...
        paths.pulseGenerator, 'PulseWidth', '50');
    simulationInput = simulationInput.setBlockParameter( ...
        paths.pulseGenerator, 'PhaseDelay', '0');
    simulationInput = simulationInput.setBlockParameter( ...
        paths.referenceOffset, 'Value', '1');
    simulationInput = simulationInput.setBlockParameter( ...
        paths.referenceSwitch, 'CurrentSetting', '1');
end

function simulationInput = localBaseInput( ...
        modelName, variables, stopTime_s, mutationID, baselineKis)
    simulationInput = Simulink.SimulationInput(modelName);
    variableNames = fieldnames(variables);
    for variableIndex = 1:numel(variableNames)
        variableName = variableNames{variableIndex};
        simulationInput = simulationInput.setVariable( ...
            variableName, variables.(variableName));
    end
    simulationInput = simulationInput.setModelParameter( ...
        'StopTime', sprintf('%.17g', stopTime_s), ...
        'SignalLogging', 'on', ...
        'SignalLoggingName', 'logsout', ...
        'SignalLoggingSaveFormat', 'Dataset', ...
        'ReturnWorkspaceOutputs', 'on');
    simulationInput = localApplyMutation( ...
        simulationInput, modelName, mutationID, baselineKis);
end

function simulationInput = localApplyMutation( ...
        simulationInput, modelName, mutationID, baselineKis)
    switch mutationID
        case "BASELINE"
            return;
        case "MUT-001"
            simulationInput = simulationInput.setVariable('Kis', 0);
        case "MUT-002"
            simulationInput = simulationInput.setVariable( ...
                'Kis', -abs(baselineKis));
        case "MUT-003"
            simulationInput = simulationInput.setBlockParameter( ...
                [modelName, '/PI Speed Controller/Subtract'], ...
                'Inputs', '++');
        case "MUT-004"
            simulationInput = simulationInput.setBlockParameter( ...
                [modelName, '/PI Speed Controller/Saturation'], ...
                'UpperLimit', '13');
        case "MUT-005"
            simulationInput = simulationInput.setBlockParameter( ...
                [modelName, '/PI Speed Controller/Saturation'], ...
                'LowerLimit', '-13');
        case "MUT-006"
            simulationInput = simulationInput.setBlockParameter( ...
                [modelName, '/PI Speed Controller/Saturation'], ...
                'UpperLimit', '0');
        otherwise
            error('run_manual_mutation_analysis:UnknownMutation', ...
                'Unknown mutation ID: %s', mutationID);
    end
end

function signals = localExtractSignals(simulationOutput)
    loggedSignals = simulationOutput.get('logsout');
    referenceSignal = localGetLoggedSignal(loggedSignals, 'reference');
    motorSpeedSignal = localGetLoggedSignal(loggedSignals, 'motorspeed');
    rawPiSignal = localGetLoggedSignal(loggedSignals, 'raw_pi_output');
    vcmdSignal = localGetLoggedSignal(loggedSignals, 'Vcmd');

    signals.time = double(motorSpeedSignal.Time(:));
    signals.motorspeed = localSignalData(motorSpeedSignal);
    signals.reference = localAlignSignal(referenceSignal, signals.time);
    signals.rawPiOutput = localAlignSignal(rawPiSignal, signals.time);
    signals.Vcmd = localAlignSignal(vcmdSignal, signals.time);
end

function nonFinite = localHasNonFinite(signals)
    nonFinite = any(~isfinite(signals.time)) || ...
        any(~isfinite(signals.reference)) || ...
        any(~isfinite(signals.motorspeed)) || ...
        any(~isfinite(signals.rawPiOutput)) || ...
        any(~isfinite(signals.Vcmd));
end

function [overallPass, passedSegments] = ...
        localEvaluateRepeatedReversal(signals)
    plateauDuration_s = 2;
    totalSegmentCount = 6;
    segmentPass = false(totalSegmentCount, 1);

    for segmentIndex = 1:totalSegmentCount
        if mod(segmentIndex, 2) == 1
            expectedReference = 15;
        else
            expectedReference = -15;
        end
        segmentStart_s = (segmentIndex - 1) * plateauDuration_s;
        segmentEnd_s = segmentIndex * plateauDuration_s;
        segmentRows = signals.time >= segmentStart_s & ...
            signals.time < segmentEnd_s;
        if ~any(segmentRows)
            error('run_manual_mutation_analysis:EmptySegment', ...
                'No logged samples were found for segment %d.', segmentIndex);
        end
        segmentTime = signals.time(segmentRows);
        segmentReference = signals.reference(segmentRows);
        segmentMotorSpeed = signals.motorspeed(segmentRows);
        if any(segmentReference ~= expectedReference)
            error('run_manual_mutation_analysis:UnexpectedReference', ...
                'Unexpected reference in repeated-reversal segment %d.', ...
                segmentIndex);
        end
        directionResult = evaluate_direction( ...
            segmentTime, segmentReference, segmentMotorSpeed);
        trackingResult = evaluate_tracking( ...
            segmentTime, segmentReference, segmentMotorSpeed);
        segmentPass(segmentIndex) = ...
            directionResult.pass && trackingResult.pass;
    end
    passedSegments = sum(segmentPass);
    overallPass = all(segmentPass);
end

function [valid, reason] = localValidateMutationApplicability( ...
        modelName, baselineKis, Vdc, mutation)
    valid = false;
    reason = "";
    mutationID = mutation.MutationID;
    gainPath = [modelName, '/PI Speed Controller/Gain'];
    subtractPath = [modelName, '/PI Speed Controller/Subtract'];
    saturationPath = [modelName, '/PI Speed Controller/Saturation'];

    try
        switch mutationID
            case "MUT-001"
                assert(strcmp(get_param(gainPath, 'Gain'), 'Kis'));
                assert(isfinite(baselineKis) && baselineKis ~= 0);
                assert(mutation.MutatedValue == "0");
            case "MUT-002"
                assert(strcmp(get_param(gainPath, 'Gain'), 'Kis'));
                assert(isfinite(baselineKis) && baselineKis > 0);
                assert(mutation.MutatedValue == "-abs(Kis)");
            case "MUT-003"
                assert(strcmp(get_param(subtractPath, 'Inputs'), '+-'));
                assert(mutation.MutatedValue == "++");
            case "MUT-004"
                assert(strcmp(get_param(saturationPath, 'UpperLimit'), 'Vdc'));
                assert(Vdc == 12 && mutation.MutatedValue == "13");
            case "MUT-005"
                assert(strcmp(get_param(saturationPath, 'LowerLimit'), '-Vdc'));
                assert(Vdc == 12 && mutation.MutatedValue == "-13");
            case "MUT-006"
                assert(strcmp(get_param(saturationPath, 'UpperLimit'), 'Vdc'));
                assert(Vdc == 12 && mutation.MutatedValue == "0");
            otherwise
                reason = "Unknown mutation ID";
                return;
        end
    catch exception
        reason = "Mutation target or frozen value does not match model: " + ...
            string(exception.message);
        return;
    end
    valid = true;
end

function rows = localInvalidExecutionRows(definitions, reason)
    rowCount = height(definitions);
    Pass = false(rowCount, 1);
    KillReason = repmat("MutationNotApplied: " + reason, rowCount, 1);
    KeyMetric = strings(rowCount, 1);
    KeyMetricValue = NaN(rowCount, 1);
    ErrorMessage = repmat(reason, rowCount, 1);
    rows = [definitions, table( ...
        Pass, KillReason, KeyMetric, KeyMetricValue, ErrorMessage)];
end

function localValidateMutationFile(mutations)
    requiredColumns = [ ...
        "MutationID", "MutationName", "Category", "Target", ...
        "BaselineValue", "MutatedValue", "FaultDescription", ...
        "ExpectedAffectedRequirement", "Status"];
    assert(all(ismember(requiredColumns, string(mutations.Properties.VariableNames))), ...
        'Mutation definition is missing one or more required columns.');
    expectedIDs = compose("MUT-%03d", (1:6).');
    assert(height(mutations) == 6 && ...
        isequal(mutations.MutationID, expectedIDs), ...
        'The frozen primary mutation set must contain MUT-001 through MUT-006.');
    assert(all(mutations.Status == "Defined - Not Executed"), ...
        'Unexpected mutation definition Status.');
end

function paths = localResolveModelPaths(modelName)
    blocks = find_system(modelName, ...
        'LookUnderMasks', 'all', 'FollowLinks', 'on', ...
        'BlockType', 'DiscretePulseGenerator');
    assert(numel(blocks) == 1, ...
        'Expected exactly one DiscretePulseGenerator block.');
    paths = struct( ...
        'pulseGenerator', blocks{1}, ...
        'referenceOffset', [modelName, '/Constant2'], ...
        'referenceSwitch', [modelName, '/Manual Switch']);
end

function data = localSignalData(signal)
    data = double(squeeze(signal.Data));
    data = data(:);
end

function value = localAlignSignal(signal, targetTime)
    signalTime = double(signal.Time(:));
    signalData = localSignalData(signal);
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
        error('run_manual_mutation_analysis:MissingSignal', ...
            'Logged signal "%s" was not found.', signalName);
    end
    signal = signalElement.Values;
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
