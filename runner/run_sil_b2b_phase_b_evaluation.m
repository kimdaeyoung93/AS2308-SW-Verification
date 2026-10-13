function phaseBResult = run_sil_b2b_phase_b_evaluation(varargin)
%RUN_SIL_B2B_PHASE_B_EVALUATION Run Protocol v1.2 independent evaluation.
%
%   The frozen Manual and Official AI execution sources are audited before
%   any simulation. Phase A identities and duplicate remaining identities
%   are classified SUPPLEMENTAL / NON-INDEPENDENT and excluded from the
%   independent aggregate. Each independent scenario runs on the derived
%   verification model in Normal and top-model SIL modes.
%
%   Numerical acceptance is exactly the frozen Protocol v1.2 formula:
%       scale(k) = max(1, abs(Model(k)), abs(SIL(k)))
%       tol(k)   = 64 * eps(scale(k))

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'Execute', true, ...
        @(x) islogical(x) && isscalar(x));
    parse(parser, varargin{:});
    executeEvaluation = parser.Results.Execute;

    protocolVersion = "v1.2 Frozen";
    expectedSourceHash = ...
        "4A7FDC070506CA641ACBD2C3EFEA2FEF71DDCC150CA3FC1F20F191B8B998ED4D";
    expectedDerivedHash = ...
        "0223B483023B87DE70FA440558AF651DF4B21DCD9B8C7095772A6CDFAB18D565";
    sourceModelName = 'AS2308_MIL_Baseline_v3';
    derivedModelName = 'AS2308_SIL_B2B_Verification_v1';

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    sourceFile = fullfile(repositoryRoot, 'model', ...
        [sourceModelName, '.slx']);
    derivedFile = fullfile(repositoryRoot, 'model', 'verification', ...
        [derivedModelName, '.slx']);
    protocolFile = fullfile(repositoryRoot, 'docs', ...
        '04_SIL_BackToBack_Protocol_v1.2.md');
    parameterScript = fullfile(repositoryRoot, 'model', ...
        'AS2308_calculate_pi_control_cc.m');
    manualSuiteFile = fullfile(runnerDirectory, 'run_manual_mil_suite.m');
    singleReversalFile = fullfile( ...
        runnerDirectory, 'run_single_reversal_test.m');
    repeatedReversalFile = fullfile( ...
        runnerDirectory, 'run_repeated_reversal_test.m');
    aiSpecFile = fullfile(repositoryRoot, 'ai', 'output', ...
        'ai_suite_v1_resolved_execution_spec.csv');
    buildRoot = fullfile(repositoryRoot, 'build', 'sil_b2b_phase_b_v1');
    cacheDirectory = fullfile(buildRoot, 'cache');
    codegenDirectory = fullfile(buildRoot, 'codegen');
    resultDirectory = fullfile(repositoryRoot, 'results', ...
        'sil_b2b_phase_b_v1');
    generatedMatFile = fullfile(repositoryRoot, ...
        [derivedModelName, '.mat']);
    generatedMatExistedBefore = isfile(generatedMatFile);

    requiredFiles = {sourceFile, derivedFile, protocolFile, ...
        parameterScript, manualSuiteFile, singleReversalFile, ...
        repeatedReversalFile, aiSpecFile};
    for index = 1:numel(requiredFiles)
        assert(isfile(requiredFiles{index}), ...
            'run_sil_b2b_phase_b_evaluation:MissingFile', ...
            'Required file not found: %s', requiredFiles{index});
    end
    localEnsureDirectory(cacheDirectory);
    localEnsureDirectory(codegenDirectory);
    localEnsureDirectory(resultDirectory);

    sourceHashBefore = localFileSha256(sourceFile);
    derivedHashBefore = localFileSha256(derivedFile);
    assert(strcmpi(sourceHashBefore, expectedSourceHash), ...
        'run_sil_b2b_phase_b_evaluation:SourceHashMismatch', ...
        'Frozen source SHA-256 mismatch before Phase B.');
    assert(strcmpi(derivedHashBefore, expectedDerivedHash), ...
        'run_sil_b2b_phase_b_evaluation:DerivedHashMismatch', ...
        'Frozen derived SHA-256 mismatch before Phase B.');

    run(parameterScript);
    parameters = struct('Kps', Kps, 'Kis', Kis, 'Kas', Kas, ...
        'Vdc', Vdc, 'ts', ts);
    localAssertFrozenParameters(parameters);

    totalTimer = tic;
    scenarios = localReadFrozenCandidatePool( ...
        manualSuiteFile, singleReversalFile, repeatedReversalFile, ...
        aiSpecFile, parameters.ts);
    [scenarios, auditTable, independentIndices, auditSummary] = ...
        localAuditScenarios(scenarios, parameters.ts);
    writetable(auditTable, fullfile( ...
        resultDirectory, 'scenario_audit.csv'));

    fprintf('\nSIL B2B Phase B pre-execution audit — %s\n', ...
        protocolVersion);
    fprintf('Candidate executions: %d\n', auditSummary.candidate_count);
    fprintf('Unique execution IDs: %d\n', auditSummary.unique_id_count);
    fprintf('Phase A ID exclusions: %d\n', ...
        auditSummary.phase_a_id_exclusion_count);
    fprintf('Phase A identity exclusions: %d\n', ...
        auditSummary.phase_a_identity_exclusion_count);
    fprintf('Remaining identity duplicates: %d\n', ...
        auditSummary.remaining_duplicate_count);
    fprintf('Independent Manual / AI / total: %d / %d / %d\n', ...
        auditSummary.manual_independent_count, ...
        auditSummary.ai_independent_count, ...
        auditSummary.total_independent_count);
    if auditSummary.total_independent_count ~= 15
        fprintf(['NOTICE: independent count differs from candidate ', ...
            'maximum 15 because of recorded identity exclusions.\n']);
    end
    fprintf('Pre-execution audit: PASS\n\n');

    if ~executeEvaluation
        phaseBResult = struct( ...
            'audit', auditTable, ...
            'audit_summary', auditSummary, ...
            'evaluation_summary', table(), ...
            'signal_metrics', table(), ...
            'build_reuse_evidence', table(), ...
            'source_hash_before', sourceHashBefore, ...
            'source_hash_after', sourceHashBefore, ...
            'derived_hash_before', derivedHashBefore, ...
            'derived_hash_after', derivedHashBefore, ...
            'total_elapsed_s', toc(totalTimer), ...
            'result_directory', string(resultDirectory));
        fprintf('Execution requested: false; no simulation or build performed.\n\n');
        return;
    end

    derivedWasLoaded = bdIsLoaded(derivedModelName);
    if ~derivedWasLoaded
        load_system(derivedFile);
    end
    modelCleanup = onCleanup(@() localRestoreModelLoadState( ...
        derivedModelName, derivedWasLoaded));
    assert(strcmp(get_param(derivedModelName, 'Dirty'), 'off'), ...
        'run_sil_b2b_phase_b_evaluation:DirtyDerivedModel', ...
        'Derived model must be clean before Phase B.');
    localAssertStoredConfiguration(derivedModelName, parameters.ts);
    localAssertRootInterface(derivedModelName);

    currentFileGenConfig = Simulink.fileGenControl('getConfig');
    originalFileGenConfig = struct( ...
        'CacheFolder', currentFileGenConfig.CacheFolder, ...
        'CodeGenFolder', currentFileGenConfig.CodeGenFolder, ...
        'CodeGenFolderStructure', ...
            currentFileGenConfig.CodeGenFolderStructure);
    fileGenCleanup = onCleanup(@() localRestoreFileGeneration( ...
        originalFileGenConfig));
    Simulink.fileGenControl('set', ...
        'CacheFolder', cacheDirectory, ...
        'CodeGenFolder', codegenDirectory, ...
        'createDir', true);

    executionIndices = localGroupByDuration(scenarios, independentIndices);
    summaryRows = repmat(localEmptySummary(), numel(executionIndices), 1);
    metricRows = repmat(localEmptyMetric(), 0, 1);
    buildRows = repmat(localEmptyBuildEvidence(), ...
        numel(executionIndices), 1);

    fprintf('Phase B independent execution order (grouped by duration):\n');
    for orderIndex = 1:numel(executionIndices)
        scenario = scenarios(executionIndices(orderIndex));
        fprintf('  %02d: %s | %.6g s\n', orderIndex, ...
            scenario.execution_id, scenario.total_duration_s);
    end
    fprintf('\n');

    for orderIndex = 1:numel(executionIndices)
        scenarioIndex = executionIndices(orderIndex);
        scenario = scenarios(scenarioIndex);
        summary = localEmptySummary();
        summary.EvaluationOrder = orderIndex;
        summary.Suite = scenario.suite;
        summary.ExecutionID = scenario.execution_id;
        summary.DisplayID = scenario.display_id;
        summary.ScenarioIdentity = scenario.identity;
        summary.InputDescription = scenario.input_description;
        summary.Status = "EXECUTION_ERROR";
        buildEvidence = localEmptyBuildEvidence();
        buildEvidence.EvaluationOrder = orderIndex;
        buildEvidence.ExecutionID = scenario.execution_id;

        fprintf('[%d/%d] %s — %s\n', orderIndex, ...
            numel(executionIndices), scenario.execution_id, ...
            scenario.input_description);
        try
            normalInput = localSimulationInput( ...
                derivedModelName, parameters, scenario, ...
                'normal'); %#ok<NASGU>
            lastwarn('', '');
            normalTimer = tic;
            normalConsole = evalc( ...
                'normalOutput = sim(normalInput);');
            summary.NormalElapsed_s = toc(normalTimer);
            [normalWarningText, normalWarningID] = lastwarn;
            normalSignals = localRootOutputs(normalOutput, scenario);
            summary.NormalExecutionSuccess = true;

            beforeSnapshot = localBuildSnapshot(buildRoot);
            silInput = localSimulationInput( ...
                derivedModelName, parameters, scenario, ...
                'Software-in-the-Loop (SIL)'); %#ok<NASGU>
            lastwarn('', '');
            silTimer = tic;
            silConsole = evalc('silOutput = sim(silInput);');
            summary.SILElapsed_s = toc(silTimer);
            [silWarningText, silWarningID] = lastwarn;
            silSignals = localRootOutputs(silOutput, scenario);
            afterSnapshot = localBuildSnapshot(buildRoot);
            summary.SILExecutionSuccess = true;

            localRelocateGeneratedRuntimeMat( ...
                generatedMatFile, generatedMatExistedBefore, ...
                buildRoot, scenario.execution_id);
            generatedMatExistedBefore = isfile(generatedMatFile);

            buildEvidence = localAnalyzeBuildEvidence( ...
                orderIndex, scenario.execution_id, beforeSnapshot, ...
                afterSnapshot, silConsole, buildRoot, ...
                summary.SILElapsed_s);
            summary.CodeGenerationOccurred = ...
                buildEvidence.CodeGenerationOccurred;
            summary.CompilationOccurred = ...
                buildEvidence.CompilationOccurred;
            summary.RelinkOccurred = buildEvidence.RelinkOccurred;
            summary.ExecutableReused = buildEvidence.ExecutableReused;
            summary.ExecutableSHA256 = ...
                buildEvidence.ExecutableSHA256;

            summary = localAssertAndRecordTimeGrid( ...
                summary, normalSignals, silSignals);
            newMetrics = localNumericalMetrics( ...
                scenario.execution_id, normalSignals, silSignals);
            metricRows = [metricRows; newMetrics]; %#ok<AGROW>
            exceeding = sum([newMetrics.ToleranceExceedingSampleCount]);
            if exceeding == 0
                summary.Status = "PASS";
            else
                summary.Status = "FAIL";
            end
            summary.ExactEquality = all([newMetrics.ExactEquality]);
            summary.ToleranceExceedingSampleCount = exceeding;
            summary.WorstNormalizedNumericalError = max( ...
                [newMetrics.MaxNormalizedNumericalError]);

            [warningOccurred, unsupportedContinuous, classification] = ...
                localWarningEvidence(normalConsole, silConsole, ...
                normalWarningText, silWarningText, true);
            summary.WarningOccurred = warningOccurred;
            summary.UnsupportedContinuousWarning = unsupportedContinuous;
            summary.WarningClassification = classification;
            summary.NormalWarningIdentifier = string(normalWarningID);
            summary.NormalWarningText = localOneLine(normalWarningText);
            summary.SILWarningIdentifier = string(silWarningID);
            summary.SILWarningText = localOneLine(silWarningText);
        catch exception
            summary.Status = "EXECUTION_ERROR";
            summary.ErrorIdentifier = string(exception.identifier);
            summary.ErrorMessage = string(exception.message);
        end

        summaryRows(orderIndex) = summary;
        buildRows(orderIndex) = buildEvidence;
        fprintf('  Status: %s | Normal %.3f s | SIL %.3f s\n', ...
            summary.Status, summary.NormalElapsed_s, summary.SILElapsed_s);
        fprintf('  Codegen/compile/relink/reuse: %d/%d/%d/%d\n\n', ...
            summary.CodeGenerationOccurred, summary.CompilationOccurred, ...
            summary.RelinkOccurred, summary.ExecutableReused);
    end

    sourceHashAfter = localFileSha256(sourceFile);
    derivedHashAfter = localFileSha256(derivedFile);
    integrityOK = strcmpi(sourceHashBefore, expectedSourceHash) && ...
        strcmpi(sourceHashAfter, expectedSourceHash) && ...
        strcmpi(derivedHashBefore, expectedDerivedHash) && ...
        strcmpi(derivedHashAfter, expectedDerivedHash) && ...
        strcmp(get_param(derivedModelName, 'Dirty'), 'off');
    if ~integrityOK
        for index = 1:numel(summaryRows)
            summaryRows(index).Status = "EXECUTION_ERROR";
            if strlength(summaryRows(index).ErrorMessage) == 0
                summaryRows(index).ErrorIdentifier = ...
                    "run_sil_b2b_phase_b_evaluation:IntegrityFailure";
                summaryRows(index).ErrorMessage = ...
                    "Frozen source or derived integrity check failed.";
            end
        end
    end

    summaryTable = struct2table(summaryRows);
    signalMetricsTable = localMetricTable(metricRows);
    buildEvidenceTable = struct2table(buildRows);
    totalElapsed_s = toc(totalTimer);

    writetable(summaryTable, fullfile( ...
        resultDirectory, 'evaluation_summary.csv'));
    writetable(signalMetricsTable, fullfile( ...
        resultDirectory, 'signal_metrics.csv'));
    writetable(buildEvidenceTable, fullfile( ...
        resultDirectory, 'build_reuse_evidence.csv'));
    localWriteMetadata(fullfile(resultDirectory, 'metadata.txt'), ...
        protocolVersion, auditSummary, summaryTable, ...
        signalMetricsTable, sourceFile, derivedFile, ...
        sourceHashBefore, sourceHashAfter, derivedHashBefore, ...
        derivedHashAfter, integrityOK, parameters, buildRoot, ...
        totalElapsed_s);

    phaseBResult = struct( ...
        'audit', auditTable, ...
        'audit_summary', auditSummary, ...
        'evaluation_summary', summaryTable, ...
        'signal_metrics', signalMetricsTable, ...
        'build_reuse_evidence', buildEvidenceTable, ...
        'source_hash_before', sourceHashBefore, ...
        'source_hash_after', sourceHashAfter, ...
        'derived_hash_before', derivedHashBefore, ...
        'derived_hash_after', derivedHashAfter, ...
        'total_elapsed_s', totalElapsed_s, ...
        'result_directory', string(resultDirectory));

    fprintf('Phase B independent evaluation complete.\n');
    fprintf('PASS / FAIL / EXECUTION_ERROR: %d / %d / %d\n', ...
        sum(summaryTable.Status == "PASS"), ...
        sum(summaryTable.Status == "FAIL"), ...
        sum(summaryTable.Status == "EXECUTION_ERROR"));
    fprintf('Total elapsed time: %.3f s\n', totalElapsed_s);
    fprintf('Source SHA before/after: %s / %s\n', ...
        sourceHashBefore, sourceHashAfter);
    fprintf('Derived SHA before/after: %s / %s\n\n', ...
        derivedHashBefore, derivedHashAfter);

    clear fileGenCleanup;
    clear modelCleanup;
end

function scenarios = localReadFrozenCandidatePool( ...
        manualFile, singleFile, repeatedFile, aiSpecFile, sampleTime)
    manualSource = fileread(manualFile);
    singleSource = fileread(singleFile);
    repeatedSource = fileread(repeatedFile);

    constantBody = localRegexToken(manualSource, ...
        'constantReferences\s*=\s*\[([^\]]+)\]\s*;');
    constantReferences = sscanf(regexprep( ...
        constantBody, '[;,]', ' '), '%f').';
    assert(isequal(constantReferences, ...
        [16.75, -16.75, 2, -2, 15, -15]), ...
        'Frozen Manual constant-reference vector changed.');
    constantDuration = str2double(localRegexToken(manualSource, ...
        'constantReferences\(runIndex\),\s*([0-9.]+)\s*\);'));

    switchingTime = str2double(localRegexToken(singleSource, ...
        'SwitchingTime_s''\s*,\s*([0-9.]+)'));
    reversalStopTime = str2double(localRegexToken(singleSource, ...
        'StopTime_s''\s*,\s*([0-9.]+)'));
    initialBody = localRegexToken(singleSource, ...
        'initial_reference_rps\s*=\s*\[([^\]]+)\]\s*;');
    initialReferences = sscanf(regexprep( ...
        initialBody, '[;,]', ' '), '%f').';
    assert(isequal(initialReferences, [15, -15]));

    plateauDuration = str2double(localRegexToken(repeatedSource, ...
        'PlateauDuration_s''\s*,\s*([0-9.]+)'));
    repeatCount = str2double(localRegexToken(repeatedSource, ...
        'RepeatCount''\s*,\s*([0-9.]+)'));
    positiveLevel = str2double(localRegexToken(repeatedSource, ...
        'commanded_reference_rps\(segmentIndex\)\s*=\s*([0-9.]+)\s*;'));
    negativeLevel = str2double(localRegexToken(repeatedSource, ...
        'commanded_reference_rps\(segmentIndex\)\s*=\s*(-[0-9.]+)\s*;'));

    scenarios = repmat(localEmptyScenario(), 18, 1);
    manualIDs = [ ...
        "MTC-001 / IT-001", "MTC-001 / IT-002", ...
        "MTC-002 / IT-001", "MTC-002 / IT-002", ...
        "MTC-003 / IT-001", "MTC-003 / IT-002"];
    for index = 1:6
        scenarios(index) = localScenario("Manual", ...
            "MANUAL:" + replace(manualIDs(index), " ", ""), ...
            manualIDs(index), constantReferences(index), ...
            constantDuration, constantDuration, false, sampleTime);
    end
    scenarios(7) = localScenario("Manual", ...
        "MANUAL:MTC-004/IT-001", "MTC-004 / IT-001", ...
        [initialReferences(1), -initialReferences(1)], ...
        switchingTime, reversalStopTime, false, sampleTime);
    scenarios(8) = localScenario("Manual", ...
        "MANUAL:MTC-004/IT-002", "MTC-004 / IT-002", ...
        [initialReferences(2), -initialReferences(2)], ...
        switchingTime, reversalStopTime, false, sampleTime);
    repeatedValues = repmat([positiveLevel, negativeLevel], ...
        1, repeatCount);
    scenarios(9) = localScenario("Manual", ...
        "MANUAL:MTC-005/IT-001", "MTC-005 / IT-001", ...
        repeatedValues, plateauDuration, ...
        numel(repeatedValues) * plateauDuration, true, sampleTime);

    options = detectImportOptions(aiSpecFile, 'TextType', 'string');
    aiSpec = readtable(aiSpecFile, options);
    expectedAI = ["TC-DIR-001"; "TC-DIR-002"; "TC-REV-001"; ...
        "TC-REV-003"; "TC-TRK-003"; "TC-TRK-005"; ...
        "TC-TRK-007"; "TC-VOLT-004"; "TC-VOLT-006"];
    assert(height(aiSpec) == 9 && ...
        isequal(aiSpec.candidate_id, expectedAI), ...
        'Frozen Official AI execution specification changed.');
    assert(all(aiSpec.sample_time_s == sampleTime));
    for index = 1:9
        values = double(jsondecode(char( ...
            aiSpec.original_input_values(index))));
        values = values(:).';
        assert(numel(values) == aiSpec.segment_count(index));
        assert(aiSpec.total_duration_s(index) == ...
            numel(values) * aiSpec.segment_duration_s(index));
        scenarios(9 + index) = localScenario("AI", ...
            "AI:" + aiSpec.candidate_id(index), ...
            aiSpec.candidate_id(index), values, ...
            aiSpec.segment_duration_s(index), ...
            aiSpec.total_duration_s(index), ...
            numel(values) > 1, sampleTime);
    end
end

function token = localRegexToken(source, expression)
    tokens = regexp(source, expression, 'tokens', 'once');
    assert(~isempty(tokens) && numel(tokens) == 1, ...
        'Could not parse frozen source expression: %s', expression);
    token = tokens{1};
end

function scenario = localScenario(suite, executionID, displayID, ...
        values, segmentDuration, totalDuration, terminalWrap, sampleTime)
    values = double(values(:).');
    assert(~isempty(values) && all(isfinite(values)));
    assert(segmentDuration > 0 && totalDuration > 0);
    assert(totalDuration == numel(values) * segmentDuration);
    sampleCount = round(totalDuration / sampleTime);
    time = (0:sampleCount)' * sampleTime;
    assert(time(end) == totalDuration);
    inputValues = zeros(size(time));
    for index = 1:numel(values)
        startTime = (index - 1) * segmentDuration;
        if index < numel(values)
            rows = time >= startTime & time < index * segmentDuration;
        else
            rows = time >= startTime & time <= totalDuration;
        end
        inputValues(rows) = values(index);
    end
    if terminalWrap
        inputValues(end) = values(1);
    end
    transitions = (1:numel(values) - 1) * segmentDuration;
    initialSemantics = "INITIALIZED_AT_REST";
    identity = localIdentity(values, transitions, totalDuration, ...
        initialSemantics);
    scenario = localEmptyScenario();
    scenario.suite = suite;
    scenario.execution_id = executionID;
    scenario.display_id = displayID;
    scenario.values_rps = values;
    scenario.segment_duration_s = segmentDuration;
    scenario.transition_times_s = transitions;
    scenario.total_duration_s = totalDuration;
    scenario.initial_reference_semantics = initialSemantics;
    scenario.exclude_terminal_sample = terminalWrap;
    scenario.time_s = time;
    scenario.input_values_rps = inputValues;
    scenario.identity = identity;
    scenario.input_description = localInputDescription(values, ...
        segmentDuration, totalDuration, terminalWrap);
end

function identity = localIdentity(values, transitions, totalDuration, initial)
    valueText = strjoin(compose('%.17g', values), ',');
    transitionText = strjoin(compose('%.17g', transitions), ',');
    identity = "segments=[" + valueText + "]|transitions=[" + ...
        transitionText + "]|duration=" + compose('%.17g', totalDuration) + ...
        "|initial=" + initial;
end

function description = localInputDescription( ...
        values, segmentDuration, totalDuration, terminalWrap)
    description = "values=[" + strjoin(compose('%.17g', values), ',') + ...
        "] rps; segment=" + compose('%.17g', segmentDuration) + ...
        " s; total=" + compose('%.17g', totalDuration) + " s";
    if terminalWrap
        description = description + "; terminal wrap sample excluded";
    end
end

function [scenarios, auditTable, independentIndices, summary] = ...
        localAuditScenarios(scenarios, sampleTime)
    assert(numel(scenarios) == 18, 'Candidate pool must contain 18 rows.');
    executionIDs = string({scenarios.execution_id}).';
    assert(numel(unique(executionIDs)) == 18, ...
        'Candidate execution IDs must be unique.');

    phaseAIDs = ["MANUAL:MTC-002/IT-001"; ...
        "MANUAL:MTC-001/IT-001"; "MANUAL:MTC-004/IT-001"];
    phaseAScenarios = [ ...
        localScenario("PhaseA", "A1", "A1", 2, 1, 1, false, sampleTime); ...
        localScenario("PhaseA", "A2", "A2", 16.75, 1, 1, false, sampleTime); ...
        localScenario("PhaseA", "A3", "A3", [15, -15], 2, 4, false, sampleTime)];
    phaseAIdentities = string({phaseAScenarios.identity}).';

    phaseAIDExcluded = ismember(executionIDs, phaseAIDs);
    identities = string({scenarios.identity}).';
    phaseAIdentityExcluded = ismember(identities, phaseAIdentities);
    duplicateRemaining = false(18, 1);
    firstIdentityRows = containers.Map('KeyType', 'char', ...
        'ValueType', 'double');
    for index = 1:18
        if phaseAIDExcluded(index) || phaseAIdentityExcluded(index)
            continue;
        end
        key = char(identities(index));
        if isKey(firstIdentityRows, key)
            duplicateRemaining(index) = true;
        else
            firstIdentityRows(key) = index;
        end
    end

    classification = repmat("INDEPENDENT", 18, 1);
    reason = repmat("NONE", 18, 1);
    for index = 1:18
        if phaseAIDExcluded(index) && phaseAIdentityExcluded(index)
            classification(index) = "SUPPLEMENTAL / NON-INDEPENDENT";
            reason(index) = "PHASE_A_ID_AND_IDENTITY";
        elseif phaseAIdentityExcluded(index)
            classification(index) = "SUPPLEMENTAL / NON-INDEPENDENT";
            reason(index) = "PHASE_A_SCENARIO_IDENTITY";
        elseif phaseAIDExcluded(index)
            classification(index) = "SUPPLEMENTAL / NON-INDEPENDENT";
            reason(index) = "PHASE_A_EXECUTION_ID";
        elseif duplicateRemaining(index)
            classification(index) = "SUPPLEMENTAL / NON-INDEPENDENT";
            reason(index) = "DUPLICATE_REMAINING_IDENTITY";
        end
    end
    independentIndices = find(classification == "INDEPENDENT");

    expectedManualRemaining = [ ...
        "MANUAL:MTC-001/IT-002"; "MANUAL:MTC-002/IT-002"; ...
        "MANUAL:MTC-003/IT-001"; "MANUAL:MTC-003/IT-002"; ...
        "MANUAL:MTC-004/IT-002"; "MANUAL:MTC-005/IT-001"];
    actualManualRemaining = executionIDs(independentIndices( ...
        string({scenarios(independentIndices).suite}).' == "Manual"));
    assert(isequal(sort(actualManualRemaining), ...
        sort(expectedManualRemaining)), ...
        'Independent Manual set differs from the frozen source expectation.');
    actualAI = executionIDs(independentIndices( ...
        string({scenarios(independentIndices).suite}).' == "AI"));
    assert(numel(actualAI) == 9, ...
        'Expected all 9 frozen AI scenarios to remain independent.');

    suite = string({scenarios.suite}).';
    displayID = string({scenarios.display_id}).';
    inputDescription = string({scenarios.input_description}).';
    candidateOrder = (1:18).';
    auditTable = table(candidateOrder, suite, executionIDs, displayID, ...
        inputDescription, identities, phaseAIDExcluded, ...
        phaseAIdentityExcluded, duplicateRemaining, classification, reason, ...
        'VariableNames', {'CandidateOrder', 'Suite', 'ExecutionID', ...
        'DisplayID', 'InputDescription', 'ScenarioIdentity', ...
        'PhaseAIDExcluded', 'PhaseAIdentityExcluded', ...
        'DuplicateRemainingIdentity', 'Classification', ...
        'ExclusionReason'});

    independentSuites = suite(independentIndices);
    summary = struct( ...
        'candidate_count', 18, ...
        'unique_id_count', numel(unique(executionIDs)), ...
        'phase_a_id_exclusion_count', sum(phaseAIDExcluded), ...
        'phase_a_identity_exclusion_count', ...
            sum(phaseAIdentityExcluded), ...
        'phase_a_identity_only_exclusion_count', ...
            sum(phaseAIdentityExcluded & ~phaseAIDExcluded), ...
        'remaining_duplicate_count', sum(duplicateRemaining), ...
        'manual_independent_count', sum(independentSuites == "Manual"), ...
        'ai_independent_count', sum(independentSuites == "AI"), ...
        'total_independent_count', numel(independentIndices));
end

function order = localGroupByDuration(scenarios, independentIndices)
    durations = arrayfun(@(x) x.total_duration_s, ...
        scenarios(independentIndices));
    durations = durations(:);
    originalOrder = (1:numel(independentIndices)).';
    [~, sorted] = sortrows([durations, originalOrder], [1, 2]);
    order = independentIndices(sorted);
end

function simulationInput = localSimulationInput( ...
        modelName, parameters, scenario, mode)
    simulationInput = Simulink.SimulationInput(modelName);
    names = fieldnames(parameters);
    for index = 1:numel(names)
        simulationInput = simulationInput.setVariable( ...
            names{index}, parameters.(names{index}));
    end
    dataset = Simulink.SimulationData.Dataset;
    series = timeseries(scenario.input_values_rps, scenario.time_s);
    series.Name = 'SpeedRef_rps';
    dataset = dataset.addElement(series, 'SpeedRef_rps');
    simulationInput = simulationInput.setExternalInput(dataset);
    simulationInput = simulationInput.setModelParameter( ...
        'SimulationMode', mode, ...
        'StopTime', sprintf('%.17g', scenario.total_duration_s), ...
        'SignalLogging', 'off', ...
        'SaveOutput', 'on', 'OutputSaveName', 'yout', ...
        'SaveFormat', 'Dataset', 'SaveTime', 'on', ...
        'TimeSaveName', 'tout', 'ReturnWorkspaceOutputs', 'on');
end

function signals = localRootOutputs(output, scenario)
    yout = output.get('yout');
    assert(isa(yout, 'Simulink.SimulationData.Dataset') && ...
        yout.numElements == 2, ...
        'run_sil_b2b_phase_b_evaluation:InvalidRootOutput', ...
        'Expected two root output Dataset elements.');
    signals = struct( ...
        'Vcmd', localSignal(yout.getElement(1), 'sampled_Vcmd'), ...
        'MotorSpeed', localSignal( ...
            yout.getElement(2), 'sampled_MotorSpeed'));
    if scenario.exclude_terminal_sample
        signals.Vcmd = localTrimTerminal( ...
            signals.Vcmd, scenario.total_duration_s);
        signals.MotorSpeed = localTrimTerminal( ...
            signals.MotorSpeed, scenario.total_duration_s);
    end
end

function signal = localSignal(element, name)
    signal = struct('name', string(name), ...
        'time', double(element.Values.Time(:)), ...
        'data', double(squeeze(element.Values.Data)));
    signal.data = signal.data(:);
    assert(~isempty(signal.time) && ...
        numel(signal.time) == numel(signal.data));
    assert(all(isfinite(signal.time)) && all(isfinite(signal.data)));
    assert(all(diff(signal.time) > 0));
end

function signal = localTrimTerminal(signal, totalDuration)
    rows = signal.time < totalDuration;
    assert(any(rows) && sum(~rows) == 1, ...
        'Expected exactly one frozen terminal-wrap sample.');
    signal.time = signal.time(rows);
    signal.data = signal.data(rows);
end

function summary = localAssertAndRecordTimeGrid(summary, normal, sil)
    assert(isequal(normal.Vcmd.time, normal.MotorSpeed.time));
    assert(isequal(sil.Vcmd.time, sil.MotorSpeed.time));
    assert(isequal(normal.Vcmd.time, sil.Vcmd.time), ...
        'run_sil_b2b_phase_b_evaluation:TimeGridMismatch', ...
        ['Normal/SIL time vectors must match exactly; interpolation, ', ...
         'resampling, and extrapolation are prohibited.']);
    summary.NormalSampleCount = numel(normal.Vcmd.time);
    summary.SILSampleCount = numel(sil.Vcmd.time);
    summary.NormalStartTime_s = normal.Vcmd.time(1);
    summary.NormalStopTime_s = normal.Vcmd.time(end);
    summary.SILStartTime_s = sil.Vcmd.time(1);
    summary.SILStopTime_s = sil.Vcmd.time(end);
    summary.TimeGridExact = true;
end

function rows = localNumericalMetrics(executionID, normal, sil)
    fields = ["Vcmd", "MotorSpeed"];
    signalNames = ["sampled_Vcmd", "sampled_MotorSpeed"];
    units = ["V", "rps"];
    rows = repmat(localEmptyMetric(), 2, 1);
    for index = 1:2
        modelSignal = normal.(fields(index));
        silSignal = sil.(fields(index));
        assert(isequal(modelSignal.time, silSignal.time));
        difference = modelSignal.data - silSignal.data;
        absoluteDifference = abs(difference);
        scale = max([ones(size(difference)), abs(modelSignal.data), ...
            abs(silSignal.data)], [], 2);
        tolerance = 64 * eps(scale);
        normalized = absoluteDifference ./ tolerance;
        exceeding = absoluteDifference > tolerance;
        differing = difference ~= 0;
        [maxDifference, maxIndex] = max(absoluteDifference);
        firstExceeding = find(exceeding, 1, 'first');

        row = localEmptyMetric();
        row.ExecutionID = executionID;
        row.SignalName = signalNames(index);
        row.Unit = units(index);
        row.SampleCount = numel(difference);
        row.MaxAbsDiff = maxDifference;
        row.RmsDiff = sqrt(mean(difference .^ 2));
        row.MaxTolerance = max(tolerance);
        row.MaxNormalizedNumericalError = max(normalized);
        row.DifferingSampleCount = sum(differing);
        row.ToleranceExceedingSampleCount = sum(exceeding);
        row.ExactEquality = ~any(differing);
        row.TimeOfMaxDiff_s = modelSignal.time(maxIndex);
        if ~isempty(firstExceeding)
            row.FirstExceedingIndex = firstExceeding;
            row.FirstExceedingTime_s = ...
                modelSignal.time(firstExceeding);
        end
        rows(index) = row;
    end
end

function snapshot = localBuildSnapshot(root)
    files = dir(fullfile(root, '**', '*'));
    files = files(~[files.isdir]);
    snapshot = repmat(struct('path', "", 'bytes', 0, 'datenum', 0), ...
        numel(files), 1);
    normalizedRoot = string(strrep(root, '\', '/')) + "/";
    for index = 1:numel(files)
        fullPath = string(fullfile(files(index).folder, files(index).name));
        snapshot(index).path = erase( ...
            string(strrep(fullPath, '\', '/')), normalizedRoot);
        snapshot(index).bytes = files(index).bytes;
        snapshot(index).datenum = files(index).datenum;
    end
end

function evidence = localAnalyzeBuildEvidence(order, executionID, ...
        before, after, consoleText, buildRoot, elapsed)
    changed = localChangedPaths(before, after);
    lowerConsole = lower(string(consoleText));
    codegen = contains(lowerConsole, ...
        'invoking target language compiler') || ...
        contains(lowerConsole, 'tlc code generation complete');
    compilation = localHasExtension(changed, [".obj", ".lib"]);
    relink = localHasExtension(changed, ".exe");
    [executablePath, executableHash] = localExecutableIdentity(buildRoot);
    reuseMessage = contains(lowerConsole, ...
        'generated code for') && contains(lowerConsole, 'is up to date') && ...
        contains(lowerConsole, 'skipping makefile generation and compilation');
    evidence = localEmptyBuildEvidence();
    evidence.EvaluationOrder = order;
    evidence.ExecutionID = executionID;
    evidence.CodeGenerationOccurred = codegen;
    evidence.CompilationOccurred = compilation;
    evidence.RelinkOccurred = relink;
    evidence.ExecutableReused = reuseMessage && ~compilation && ~relink;
    evidence.SILElapsed_s = elapsed;
    evidence.ChangedArtifactCount = numel(changed);
    evidence.ExecutablePath = executablePath;
    evidence.ExecutableSHA256 = executableHash;
end

function changed = localChangedPaths(before, after)
    changed = strings(0, 1);
    beforePaths = string({before.path});
    for index = 1:numel(after)
        beforeIndex = find(beforePaths == after(index).path, 1, 'first');
        if isempty(beforeIndex) || ...
                before(beforeIndex).bytes ~= after(index).bytes || ...
                before(beforeIndex).datenum ~= after(index).datenum
            changed(end + 1, 1) = after(index).path; %#ok<AGROW>
        end
    end
end

function present = localHasExtension(paths, extensions)
    present = false;
    for index = 1:numel(paths)
        [~, ~, extension] = fileparts(paths(index));
        if any(strcmpi(string(extension), extensions))
            present = true;
            return;
        end
    end
end

function [pathValue, hashValue] = localExecutableIdentity(buildRoot)
    files = dir(fullfile(buildRoot, '**', '*.exe'));
    if isempty(files)
        pathValue = "NOT_FOUND";
        hashValue = "NOT_FOUND";
        return;
    end
    [~, index] = max([files.datenum]);
    pathValue = string(fullfile(files(index).folder, files(index).name));
    hashValue = localFileSha256(pathValue);
end

function [occurred, unsupported, classification] = ...
        localWarningEvidence(normalConsole, silConsole, ...
        normalWarning, silWarning, outputsCollected)
    combined = lower(string(normalConsole) + newline + ...
        string(silConsole) + newline + string(normalWarning) + ...
        newline + string(silWarning));
    unsupported = contains(combined, ...
        "unsupported sample time: continuous");
    occurred = strlength(string(normalWarning)) > 0 || ...
        strlength(string(silWarning)) > 0 || ...
        contains(combined, "warning:") || contains(combined, "warning ");
    if unsupported && outputsCollected
        classification = "LEGACY_OR_INTERNAL_LOGGING_ONLY";
    elseif unsupported
        classification = "REQUIRED_ROOT_OUTPUT_COLLECTION_IMPACTED";
    elseif occurred
        classification = "OTHER_WARNING";
    else
        classification = "NONE";
    end
end

function localRelocateGeneratedRuntimeMat( ...
        filePath, existedBefore, buildRoot, executionID)
    if existedBefore || ~isfile(filePath)
        return;
    end
    directory = fullfile(buildRoot, 'runtime_output');
    localEnsureDirectory(directory);
    safeID = regexprep(char(executionID), '[^A-Za-z0-9_-]', '_');
    destination = fullfile(directory, [safeID, '.mat']);
    if isfile(destination)
        timestamp = char(datetime('now', ...
            'Format', 'yyyyMMdd_HHmmss_SSS'));
        destination = fullfile(directory, ...
            sprintf('%s_%s.mat', safeID, timestamp));
    end
    [moved, message] = movefile(filePath, destination);
    assert(moved, 'Could not relocate runtime MAT file: %s', message);
end

function localWriteMetadata(filePath, protocolVersion, audit, ...
        summaryTable, metricsTable, sourceFile, derivedFile, ...
        sourceBefore, sourceAfter, derivedBefore, derivedAfter, ...
        integrityOK, parameters, buildRoot, totalElapsed)
    fileIdentifier = fopen(filePath, 'wt');
    assert(fileIdentifier >= 0, 'Could not open metadata file.');
    closeFile = onCleanup(@() fclose(fileIdentifier));
    simulinkInfo = ver('simulink');
    fprintf(fileIdentifier, 'Protocol: %s\n', protocolVersion);
    fprintf(fileIdentifier, 'Phase: B Independent Evaluation\n');
    fprintf(fileIdentifier, 'MATLAB/Simulink: %s / %s\n', ...
        version('-release'), simulinkInfo.Version);
    fprintf(fileIdentifier, 'Host/compiler: %s / %s\n', ...
        computer('arch'), localCompilerDescription());
    fprintf(fileIdentifier, 'Solver/FixedStep/target: ode4 / ts / grt.tlc\n');
    fprintf(fileIdentifier, 'Kps/Kis/Kas/Vdc/ts: %.17g / %.17g / %.17g / %.17g / %.17g\n', ...
        parameters.Kps, parameters.Kis, parameters.Kas, ...
        parameters.Vdc, parameters.ts);
    fprintf(fileIdentifier, 'Candidate/independent: %d / %d\n', ...
        audit.candidate_count, audit.total_independent_count);
    fprintf(fileIdentifier, 'Manual/AI independent: %d / %d\n', ...
        audit.manual_independent_count, audit.ai_independent_count);
    fprintf(fileIdentifier, 'PASS/FAIL/EXECUTION_ERROR: %d/%d/%d\n', ...
        sum(summaryTable.Status == "PASS"), ...
        sum(summaryTable.Status == "FAIL"), ...
        sum(summaryTable.Status == "EXECUTION_ERROR"));
    fprintf(fileIdentifier, 'Tolerance formula: 64 * eps(max(1, abs(Model), abs(SIL)))\n');
    fprintf(fileIdentifier, 'Total tolerance-exceeding samples: %d\n', ...
        sum(metricsTable.ToleranceExceedingSampleCount));
    fprintf(fileIdentifier, 'Exact-equality executions: %d\n', ...
        sum(summaryTable.ExactEquality));
    fprintf(fileIdentifier, 'Source model: %s\n', sourceFile);
    fprintf(fileIdentifier, 'Source SHA before/after: %s / %s\n', ...
        sourceBefore, sourceAfter);
    fprintf(fileIdentifier, 'Derived model: %s\n', derivedFile);
    fprintf(fileIdentifier, 'Derived SHA before/after: %s / %s\n', ...
        derivedBefore, derivedAfter);
    fprintf(fileIdentifier, 'Integrity exact match: %d\n', integrityOK);
    fprintf(fileIdentifier, 'Build root: %s\n', buildRoot);
    fprintf(fileIdentifier, 'Total elapsed s: %.17g\n', totalElapsed);
    fprintf(fileIdentifier, ['Continuous internal logging was disabled; ', ...
        'required observations were discrete root outputs.\n']);
    fprintf(fileIdentifier, 'Execution timestamp: %s\n', char(datetime( ...
        'now', 'TimeZone', 'local', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ssXXX')));
    clear closeFile;
end

function row = localEmptyScenario()
    row = struct('suite', "", 'execution_id', "", 'display_id', "", ...
        'values_rps', [], 'segment_duration_s', NaN, ...
        'transition_times_s', [], 'total_duration_s', NaN, ...
        'initial_reference_semantics', "", ...
        'exclude_terminal_sample', false, 'time_s', [], ...
        'input_values_rps', [], 'identity', "", ...
        'input_description', "");
end

function row = localEmptySummary()
    row = struct('EvaluationOrder', NaN, 'Suite', "", ...
        'ExecutionID', "", 'DisplayID', "", ...
        'ScenarioIdentity', "", 'InputDescription', "", ...
        'Status', "EXECUTION_ERROR", ...
        'NormalExecutionSuccess', false, 'SILExecutionSuccess', false, ...
        'NormalSampleCount', NaN, 'SILSampleCount', NaN, ...
        'NormalStartTime_s', NaN, 'NormalStopTime_s', NaN, ...
        'SILStartTime_s', NaN, 'SILStopTime_s', NaN, ...
        'TimeGridExact', false, 'ExactEquality', false, ...
        'ToleranceExceedingSampleCount', NaN, ...
        'WorstNormalizedNumericalError', NaN, ...
        'NormalElapsed_s', NaN, 'SILElapsed_s', NaN, ...
        'CodeGenerationOccurred', false, ...
        'CompilationOccurred', false, 'RelinkOccurred', false, ...
        'ExecutableReused', false, 'ExecutableSHA256', "", ...
        'WarningOccurred', false, ...
        'UnsupportedContinuousWarning', false, ...
        'WarningClassification', "NONE", ...
        'NormalWarningIdentifier', "", 'NormalWarningText', "", ...
        'SILWarningIdentifier', "", 'SILWarningText', "", ...
        'ErrorIdentifier', "", 'ErrorMessage', "");
end

function row = localEmptyMetric()
    row = struct('ExecutionID', "", 'SignalName', "", 'Unit', "", ...
        'SampleCount', NaN, 'MaxAbsDiff', NaN, 'RmsDiff', NaN, ...
        'MaxTolerance', NaN, 'MaxNormalizedNumericalError', NaN, ...
        'DifferingSampleCount', NaN, ...
        'ToleranceExceedingSampleCount', NaN, ...
        'FirstExceedingIndex', NaN, 'FirstExceedingTime_s', NaN, ...
        'TimeOfMaxDiff_s', NaN, 'ExactEquality', false);
end

function row = localEmptyBuildEvidence()
    row = struct('EvaluationOrder', NaN, 'ExecutionID', "", ...
        'CodeGenerationOccurred', false, ...
        'CompilationOccurred', false, 'RelinkOccurred', false, ...
        'ExecutableReused', false, 'SILElapsed_s', NaN, ...
        'ChangedArtifactCount', NaN, 'ExecutablePath', "NOT_FOUND", ...
        'ExecutableSHA256', "NOT_FOUND");
end

function tableValue = localMetricTable(rows)
    if isempty(rows)
        tableValue = struct2table(localEmptyMetric());
        tableValue(1, :) = [];
    else
        tableValue = struct2table(rows);
    end
end

function localAssertFrozenParameters(parameters)
    expectedKps = (2 * pi * 40) / 2185.96;
    expectedKis = 17.76 * expectedKps;
    assert(parameters.ts == 0.0004 && parameters.Vdc == 12);
    assert(parameters.Kps == expectedKps);
    assert(parameters.Kis == expectedKis);
    assert(parameters.Kas == expectedKis / expectedKps);
end

function localAssertStoredConfiguration(modelName, sampleTime)
    assert(strcmp(get_param(modelName, 'SolverType'), 'Fixed-step'));
    assert(strcmp(get_param(modelName, 'Solver'), 'ode4'));
    assert(strcmp(get_param(modelName, 'FixedStep'), 'ts'));
    assert(strcmp(get_param(modelName, 'SystemTargetFile'), 'grt.tlc'));
    assert(strcmp(get_param(modelName, 'TargetLang'), 'C'));
    assert(sampleTime == 0.0004);
end

function localAssertRootInterface(modelName)
    assert(strcmp(get_param([modelName, '/SpeedRef_rps'], ...
        'BlockType'), 'Inport'));
    assert(strcmp(get_param([modelName, '/sampled_Vcmd'], 'Port'), '1'));
    assert(strcmp(get_param([modelName, '/sampled_MotorSpeed'], ...
        'Port'), '2'));
    assert(strcmp(get_param([modelName, '/Observe_Vcmd_ZOH'], ...
        'SampleTime'), 'ts'));
    assert(strcmp(get_param([modelName, '/Observe_MotorSpeed_ZOH'], ...
        'SampleTime'), 'ts'));
end

function description = localCompilerDescription()
    description = "NOT_CONFIGURED";
    try
        configuration = mex.getCompilerConfigurations('C', 'Selected');
        if ~isempty(configuration)
            description = string(configuration(1).Name) + " " + ...
                string(configuration(1).Version);
        end
    catch exception
        description = "UNAVAILABLE: " + string(exception.identifier);
    end
end

function localRestoreFileGeneration(config)
    Simulink.fileGenControl('set', ...
        'CacheFolder', config.CacheFolder, ...
        'CodeGenFolder', config.CodeGenFolder, ...
        'CodeGenFolderStructure', config.CodeGenFolderStructure);
end

function localRestoreModelLoadState(modelName, wasLoaded)
    if ~bdIsLoaded(modelName)
        return;
    end
    if ~strcmp(get_param(modelName, 'Dirty'), 'off')
        warning('run_sil_b2b_phase_b_evaluation:DirtyModelLeftOpen', ...
            'Derived model became dirty and was left open without saving.');
        return;
    end
    if ~wasLoaded
        close_system(modelName, 0);
    end
end

function localEnsureDirectory(directory)
    if ~isfolder(directory)
        [created, message] = mkdir(directory);
        assert(created, 'Could not create directory %s: %s', ...
            directory, message);
    end
end

function hashValue = localFileSha256(filePath)
    fileIdentifier = fopen(filePath, 'rb');
    assert(fileIdentifier >= 0, 'Could not open file: %s', filePath);
    closeFile = onCleanup(@() fclose(fileIdentifier));
    bytes = fread(fileIdentifier, Inf, '*uint8');
    clear closeFile;
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(typecast(bytes(:), 'int8'));
    hashBytes = typecast(digest.digest(), 'uint8');
    hashValue = upper(string(reshape(dec2hex( ...
        hashBytes, 2).', 1, [])));
end

function value = localOneLine(value)
    value = strtrim(replace(string(value), [newline, char(13)], " "));
end
