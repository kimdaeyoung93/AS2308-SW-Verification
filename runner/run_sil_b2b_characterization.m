function [summaryTable, signalMetricsTable, buildEvidenceTable, runData] = ...
        run_sil_b2b_characterization()
%RUN_SIL_B2B_CHARACTERIZATION Run Protocol v1.1 Phase A characterization.
%
%   This runner executes only the three frozen Phase A scenarios against
%   the derived verification model. Each scenario runs once in Normal mode
%   and once as top-model SIL. Required observations are the discrete root
%   outputs sampled_Vcmd and sampled_MotorSpeed.
%
%   Difference metrics are characterization data only. No numerical
%   equivalence tolerance or equivalence PASS/FAIL decision is defined.

    protocolVersion = "v1.1 Frozen";
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
        '04_SIL_BackToBack_Protocol_v1.1.md');
    parameterScript = fullfile(repositoryRoot, 'model', ...
        'AS2308_calculate_pi_control_cc.m');
    manualRunnerFile = fullfile(runnerDirectory, ...
        'run_manual_mil_suite.m');
    reversalRunnerFile = fullfile(runnerDirectory, ...
        'run_single_reversal_test.m');
    buildRoot = fullfile(repositoryRoot, 'build', ...
        'sil_b2b_characterization_v1_1');
    cacheDirectory = fullfile(buildRoot, 'cache');
    codegenDirectory = fullfile(buildRoot, 'codegen');
    resultDirectory = fullfile(repositoryRoot, 'results', ...
        'sil_b2b_characterization_v1_1');
    generatedMatFile = fullfile(repositoryRoot, ...
        [derivedModelName, '.mat']);
    generatedMatExistedBefore = isfile(generatedMatFile);

    localEnsureDirectory(cacheDirectory);
    localEnsureDirectory(codegenDirectory);
    localEnsureDirectory(resultDirectory);
    localAssertFile(sourceFile, 'Frozen source model');
    localAssertFile(derivedFile, 'Derived verification model');
    localAssertFile(protocolFile, 'Frozen SIL Protocol v1.1');
    localAssertFile(parameterScript, 'Controller parameter script');
    localAssertFile(manualRunnerFile, 'Frozen Manual MIL runner');
    localAssertFile(reversalRunnerFile, 'Frozen reversal runner');

    sourceHashBefore = localFileSha256(sourceFile);
    derivedHashBefore = localFileSha256(derivedFile);
    assert(strcmpi(sourceHashBefore, expectedSourceHash), ...
        'run_sil_b2b_characterization:SourceHashMismatch', ...
        'Frozen source SHA-256 mismatch.');
    assert(strcmpi(derivedHashBefore, expectedDerivedHash), ...
        'run_sil_b2b_characterization:DerivedHashMismatch', ...
        'Derived model SHA-256 mismatch.');

    run(parameterScript);
    parameters = struct('Kps', Kps, 'Kis', Kis, 'Kas', Kas, ...
        'Vdc', Vdc, 'ts', ts);
    localAssertFrozenParameters(parameters);
    localAssertFrozenScenarioDefinitions( ...
        manualRunnerFile, reversalRunnerFile);
    scenarios = localFrozenScenarios(parameters.ts);

    derivedWasLoaded = bdIsLoaded(derivedModelName);
    if ~derivedWasLoaded
        load_system(derivedFile);
    end
    modelCleanup = onCleanup(@() localRestoreModelLoadState( ...
        derivedModelName, derivedWasLoaded));
    assert(strcmp(get_param(derivedModelName, 'Dirty'), 'off'), ...
        'run_sil_b2b_characterization:DirtyDerivedModel', ...
        'Derived model must be clean before Phase A execution.');
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

    summaryRows = repmat(localEmptySummary(), numel(scenarios), 1);
    metricRows = repmat(localEmptyMetric(), 0, 1);
    buildRows = repmat(localEmptyBuildEvidence(), numel(scenarios), 1);
    runData = repmat(struct( ...
        'scenario_id', "", ...
        'normal', struct(), ...
        'sil', struct(), ...
        'normal_console', "", ...
        'sil_console', "", ...
        'status', "", ...
        'error_message', ""), numel(scenarios), 1);

    fprintf('\nSIL B2B Phase A Characterization — Protocol %s\n', ...
        protocolVersion);
    fprintf('Architecture: derived-model Normal versus top-model SIL\n');
    fprintf('Required observations: discrete root outputs only\n');
    fprintf('Numerical equivalence tolerance: NOT DEFINED\n\n');

    for scenarioIndex = 1:numel(scenarios)
        scenario = scenarios(scenarioIndex);
        summary = localEmptySummary();
        summary.ProtocolVersion = protocolVersion;
        summary.ScenarioID = scenario.id;
        summary.SourceScenario = scenario.source_scenario;
        summary.InputDescription = scenario.description;
        summary.Status = "EXECUTION_ERROR";
        buildEvidence = localEmptyBuildEvidence();
        buildEvidence.ScenarioID = scenario.id;
        runData(scenarioIndex).scenario_id = scenario.id;

        fprintf('[%d/3] %s — %s\n', ...
            scenarioIndex, scenario.id, scenario.description);
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
            normalSignals = localRootOutputs(normalOutput);
            runData(scenarioIndex).normal = normalSignals;
            runData(scenarioIndex).normal_console = string(normalConsole);
            summary.NormalExecutionSuccess = true;

            beforeSnapshot = localBuildSnapshot(buildRoot);
            silInput = localSimulationInput( ...
                derivedModelName, parameters, scenario, ...
                'Software-in-the-Loop (SIL)'); %#ok<NASGU>
            lastwarn('', '');
            silTimer = tic;
            silConsole = evalc('silOutput = sim(silInput);');
            summary.SILBuildExecutionElapsed_s = toc(silTimer);
            [silWarningText, silWarningID] = lastwarn;
            silSignals = localRootOutputs(silOutput);
            afterSnapshot = localBuildSnapshot(buildRoot);
            runData(scenarioIndex).sil = silSignals;
            runData(scenarioIndex).sil_console = string(silConsole);
            summary.SILExecutionSuccess = true;

            localRelocateGeneratedRuntimeMat( ...
                generatedMatFile, generatedMatExistedBefore, ...
                buildRoot, scenario.id);
            generatedMatExistedBefore = isfile(generatedMatFile);

            buildEvidence = localAnalyzeBuildEvidence( ...
                scenario.id, beforeSnapshot, afterSnapshot, ...
                silConsole, buildRoot, ...
                summary.SILBuildExecutionElapsed_s);
            summary.CodeGenerationOccurred = ...
                buildEvidence.CodeGenerationOccurred;
            summary.CompilationOccurred = ...
                buildEvidence.CompilationOccurred;
            summary.RelinkOccurred = buildEvidence.RelinkOccurred;

            summary = localRecordTimeGrid( ...
                summary, normalSignals, silSignals);
            newMetrics = localScenarioMetrics( ...
                scenario, normalSignals, silSignals, parameters);
            metricRows = [metricRows; newMetrics]; %#ok<AGROW>

            [warningOccurred, unsupportedContinuous, ...
                    warningClassification] = localWarningEvidence( ...
                normalConsole, silConsole, normalWarningText, ...
                silWarningText, true);
            summary.WarningOccurred = warningOccurred;
            summary.UnsupportedContinuousWarning = ...
                unsupportedContinuous;
            summary.WarningClassification = warningClassification;
            summary.NormalWarningIdentifier = string(normalWarningID);
            summary.NormalWarningText = localOneLine(normalWarningText);
            summary.SILWarningIdentifier = string(silWarningID);
            summary.SILWarningText = localOneLine(silWarningText);
            summary.Status = "EXECUTION_OK";
        catch exception
            summary.Status = "EXECUTION_ERROR";
            summary.ErrorIdentifier = string(exception.identifier);
            summary.ErrorMessage = string(exception.message);
            runData(scenarioIndex).error_message = ...
                string(exception.message);
        end

        runData(scenarioIndex).status = summary.Status;
        summaryRows(scenarioIndex) = summary;
        buildRows(scenarioIndex) = buildEvidence;
        fprintf('  Status: %s | Normal %.3f s | SIL %.3f s\n', ...
            summary.Status, summary.NormalElapsed_s, ...
            summary.SILBuildExecutionElapsed_s);
        fprintf('  Codegen/compile/relink: %d/%d/%d\n\n', ...
            summary.CodeGenerationOccurred, ...
            summary.CompilationOccurred, summary.RelinkOccurred);
    end

    sourceHashAfter = localFileSha256(sourceFile);
    derivedHashAfter = localFileSha256(derivedFile);
    sourceHashUnchanged = strcmpi(sourceHashBefore, sourceHashAfter) && ...
        strcmpi(sourceHashAfter, expectedSourceHash);
    derivedHashUnchanged = strcmpi( ...
        derivedHashBefore, derivedHashAfter) && ...
        strcmpi(derivedHashAfter, expectedDerivedHash);
    modelClean = strcmp(get_param(derivedModelName, 'Dirty'), 'off');
    integrityOK = sourceHashUnchanged && derivedHashUnchanged && modelClean;

    if ~integrityOK
        for index = 1:numel(summaryRows)
            summaryRows(index).Status = "EXECUTION_ERROR";
            if strlength(summaryRows(index).ErrorMessage) == 0
                summaryRows(index).ErrorIdentifier = ...
                    "run_sil_b2b_characterization:IntegrityFailure";
                summaryRows(index).ErrorMessage = ...
                    "Source/derived integrity check failed.";
            end
        end
    end

    summaryTable = struct2table(summaryRows);
    signalMetricsTable = localMetricTable(metricRows);
    buildEvidenceTable = struct2table(buildRows);
    overallStatus = "EXECUTION_ERROR";
    if integrityOK && all(summaryTable.Status == "EXECUTION_OK")
        overallStatus = "EXECUTION_OK";
    end

    writetable(summaryTable, fullfile( ...
        resultDirectory, 'characterization_summary.csv'));
    writetable(signalMetricsTable, fullfile( ...
        resultDirectory, 'signal_metrics.csv'));
    localWriteBuildEvidence(fullfile(resultDirectory, ...
        'build_reuse_evidence.txt'), buildEvidenceTable);
    localWriteMetadata(fullfile(resultDirectory, 'metadata.txt'), ...
        protocolVersion, overallStatus, sourceFile, derivedFile, ...
        sourceHashBefore, sourceHashAfter, derivedHashBefore, ...
        derivedHashAfter, parameters, buildRoot, summaryTable, ...
        integrityOK);

    fprintf('Phase A execution status: %s\n', overallStatus);
    fprintf('Source SHA before/after: %s / %s\n', ...
        sourceHashBefore, sourceHashAfter);
    fprintf('Derived SHA before/after: %s / %s\n', ...
        derivedHashBefore, derivedHashAfter);
    fprintf(['Characterization only: no numerical equivalence ', ...
        'PASS/FAIL decision was made.\n\n']);

    clear fileGenCleanup;
    clear modelCleanup;
end

function simulationInput = localSimulationInput( ...
        modelName, parameters, scenario, simulationMode)
    simulationInput = Simulink.SimulationInput(modelName);
    names = fieldnames(parameters);
    for index = 1:numel(names)
        simulationInput = simulationInput.setVariable( ...
            names{index}, parameters.(names{index}));
    end
    inputDataset = Simulink.SimulationData.Dataset;
    inputSeries = timeseries(scenario.values_rps, scenario.time_s);
    inputSeries.Name = 'SpeedRef_rps';
    inputDataset = inputDataset.addElement(inputSeries, 'SpeedRef_rps');
    simulationInput = simulationInput.setExternalInput(inputDataset);
    simulationInput = simulationInput.setModelParameter( ...
        'SimulationMode', simulationMode, ...
        'StopTime', sprintf('%.17g', scenario.stop_time_s), ...
        'SignalLogging', 'off', ...
        'SaveOutput', 'on', ...
        'OutputSaveName', 'yout', ...
        'SaveFormat', 'Dataset', ...
        'SaveTime', 'on', ...
        'TimeSaveName', 'tout', ...
        'ReturnWorkspaceOutputs', 'on');
end

function signals = localRootOutputs(simulationOutput)
    yout = simulationOutput.get('yout');
    assert(isa(yout, 'Simulink.SimulationData.Dataset'), ...
        'run_sil_b2b_characterization:InvalidRootOutput', ...
        'Root output yout is not a Dataset.');
    assert(yout.numElements == 2, ...
        'run_sil_b2b_characterization:RootOutputCountMismatch', ...
        'Expected two root outputs, found %d.', yout.numElements);
    signals = struct( ...
        'Vcmd', localSignal(yout.getElement(1), 'sampled_Vcmd'), ...
        'MotorSpeed', localSignal( ...
            yout.getElement(2), 'sampled_MotorSpeed'));
end

function signal = localSignal(datasetElement, expectedName)
    values = datasetElement.Values;
    signal = struct('name', string(expectedName), ...
        'time', double(values.Time(:)), ...
        'data', double(squeeze(values.Data)));
    signal.data = signal.data(:);
    assert(~isempty(signal.time) && ~isempty(signal.data), ...
        'run_sil_b2b_characterization:EmptySignal', ...
        '%s is empty.', expectedName);
    assert(numel(signal.time) == numel(signal.data), ...
        'run_sil_b2b_characterization:SignalLengthMismatch', ...
        '%s time/data lengths differ.', expectedName);
    assert(all(isfinite(signal.time)) && all(isfinite(signal.data)), ...
        'run_sil_b2b_characterization:NonFiniteSignal', ...
        '%s contains NaN or Inf.', expectedName);
    assert(all(diff(signal.time) > 0), ...
        'run_sil_b2b_characterization:NonMonotonicTime', ...
        '%s time is not strictly increasing.', expectedName);
end

function summary = localRecordTimeGrid(summary, normal, sil)
    assert(localTimeGridEqual(normal.Vcmd.time, ...
        normal.MotorSpeed.time), ...
        'run_sil_b2b_characterization:NormalOutputGridMismatch', ...
        'Normal root outputs have different time grids.');
    assert(localTimeGridEqual(sil.Vcmd.time, sil.MotorSpeed.time), ...
        'run_sil_b2b_characterization:SILOutputGridMismatch', ...
        'SIL root outputs have different time grids.');
    assert(localTimeGridEqual(normal.Vcmd.time, sil.Vcmd.time), ...
        'run_sil_b2b_characterization:NormalSILGridMismatch', ...
        ['Normal and SIL time grids differ. No interpolation, ', ...
         'resampling, or extrapolation was used.']);
    summary.NormalSampleCount = numel(normal.Vcmd.time);
    summary.SILSampleCount = numel(sil.Vcmd.time);
    summary.NormalStartTime_s = normal.Vcmd.time(1);
    summary.NormalStopTime_s = normal.Vcmd.time(end);
    summary.SILStartTime_s = sil.Vcmd.time(1);
    summary.SILStopTime_s = sil.Vcmd.time(end);
    summary.TimeGridEqual = true;
end

function equal = localTimeGridEqual(leftTime, rightTime)
    leftTime = double(leftTime(:));
    rightTime = double(rightTime(:));
    if numel(leftTime) ~= numel(rightTime) || isempty(leftTime)
        equal = false;
        return;
    end
    spacing = max(eps(leftTime), eps(rightTime));
    equal = all(leftTime == rightTime | ...
        abs(leftTime - rightTime) <= spacing);
end

function rows = localScenarioMetrics(scenario, normal, sil, parameters)
    signalNames = ["sampled_Vcmd", "sampled_MotorSpeed"];
    fields = ["Vcmd", "MotorSpeed"];
    units = ["V", "rps"];
    rows = repmat(localEmptyMetric(), numel(signalNames), 1);
    for index = 1:numel(signalNames)
        left = normal.(fields(index));
        right = sil.(fields(index));
        assert(localTimeGridEqual(left.time, right.time));
        assert(numel(left.data) == numel(right.data));
        difference = left.data - right.data;
        absoluteDifference = abs(difference);
        [maximumDifference, maximumIndex] = max(absoluteDifference);
        firstDifferenceIndex = find(left.data ~= right.data, 1, 'first');

        row = localEmptyMetric();
        row.ScenarioID = scenario.id;
        row.SignalName = signalNames(index);
        row.Unit = units(index);
        row.Status = "EXECUTION_OK";
        row.SampleCount = numel(difference);
        row.MaxAbsDiff = maximumDifference;
        row.RmsDiff = sqrt(mean(difference .^ 2));
        row.DifferingSampleCount = sum(left.data ~= right.data);
        if ~isempty(firstDifferenceIndex)
            row.FirstDifferingIndex = firstDifferenceIndex;
            row.FirstDifferingTime_s = left.time(firstDifferenceIndex);
        end
        row.TimeOfMaxDiff_s = left.time(maximumIndex);
        row.NormalFirstSample = left.data(1);
        row.NormalLastSample = left.data(end);
        row.SILFirstSample = right.data(1);
        row.SILLastSample = right.data(end);

        if scenario.kind == "saturation"
            saturationMask = abs(normal.Vcmd.data) == parameters.Vdc | ...
                abs(sil.Vcmd.data) == parameters.Vdc;
            row.SaturationSampleCount = sum(saturationMask);
            if any(saturationMask)
                row.SaturationFirstTime_s = ...
                    left.time(find(saturationMask, 1, 'first'));
                row.SaturationLastTime_s = ...
                    left.time(find(saturationMask, 1, 'last'));
                row.SaturationMaxAbsDiff = ...
                    max(absoluteDifference(saturationMask));
            end
        elseif scenario.kind == "reversal"
            adjacentMask = left.time >= ...
                scenario.switch_time_s - parameters.ts & ...
                left.time <= scenario.switch_time_s + parameters.ts;
            row.TransitionWindowMaxAbsDiff = ...
                max(absoluteDifference(adjacentMask));
            row.NormalFirstNegativeTime_s = localFirstNegativeTime( ...
                left.time, left.data, scenario.switch_time_s);
            row.SILFirstNegativeTime_s = localFirstNegativeTime( ...
                right.time, right.data, scenario.switch_time_s);
        end
        row.Notes = ["Informational characterization only; no ", ...
            "numerical equivalence tolerance or PASS/FAIL is defined."];
        rows(index) = row;
    end
end

function timeValue = localFirstNegativeTime(time, data, startTime)
    index = find(time >= startTime & data < 0, 1, 'first');
    if isempty(index)
        timeValue = NaN;
    else
        timeValue = time(index);
    end
end

function scenarios = localFrozenScenarios(sampleTime)
    scenarios = repmat(struct( ...
        'id', "", 'source_scenario', "", 'kind', "", ...
        'description', "", 'stop_time_s', NaN, ...
        'switch_time_s', NaN, 'time_s', [], 'values_rps', []), 3, 1);
    scenarios(1) = localScenario("SIL-CHAR-001", ...
        "MTC-002 / IT-001", "tracking", "+2 rps, 0-1 s", ...
        1, NaN, 2, sampleTime);
    scenarios(2) = localScenario("SIL-CHAR-002", ...
        "MTC-001 / IT-001", "saturation", ...
        "+16.75 rps, 0-1 s", 1, NaN, 16.75, sampleTime);
    scenarios(3) = localScenario("SIL-CHAR-003", ...
        "MTC-004 / IT-001", "reversal", ...
        "+15 rps [0,2 s), -15 rps [2,4 s]", ...
        4, 2, [15 -15], sampleTime);
end

function scenario = localScenario(id, sourceScenario, kind, ...
        description, stopTime, switchTime, values, sampleTime)
    count = round(stopTime / sampleTime);
    time = (0:count)' * sampleTime;
    assert(time(1) == 0 && time(end) == stopTime);
    inputValues = values(1) * ones(size(time));
    if kind == "reversal"
        inputValues(time >= switchTime) = values(2);
        transitionIndex = find(time == switchTime, 1, 'first');
        assert(~isempty(transitionIndex));
        assert(inputValues(transitionIndex - 1) == values(1));
        assert(inputValues(transitionIndex) == values(2));
    end
    scenario = struct('id', id, ...
        'source_scenario', sourceScenario, 'kind', kind, ...
        'description', description, 'stop_time_s', stopTime, ...
        'switch_time_s', switchTime, 'time_s', time, ...
        'values_rps', inputValues);
end

function snapshot = localBuildSnapshot(buildRoot)
    files = dir(fullfile(buildRoot, '**', '*'));
    files = files(~[files.isdir]);
    snapshot = repmat(struct('relative_path', "", ...
        'bytes', 0, 'datenum', 0), numel(files), 1);
    normalizedRoot = string(strrep(buildRoot, '\', '/')) + "/";
    for index = 1:numel(files)
        fullPath = string(fullfile(files(index).folder, files(index).name));
        normalizedPath = string(strrep(fullPath, '\', '/'));
        snapshot(index).relative_path = erase(normalizedPath, normalizedRoot);
        snapshot(index).bytes = files(index).bytes;
        snapshot(index).datenum = files(index).datenum;
    end
end

function evidence = localAnalyzeBuildEvidence( ...
        scenarioID, before, after, consoleText, buildRoot, elapsed)
    changed = localChangedPaths(before, after);
    lowerConsole = lower(string(consoleText));
    codeExtensions = [".c", ".h"];
    compileExtensions = [".obj", ".lib"];
    linkExtensions = ".exe";
    codeChanged = localHasExtension(changed, codeExtensions);
    compileChanged = localHasExtension(changed, compileExtensions);
    linkChanged = localHasExtension(changed, linkExtensions);
    codeConsole = ...
        contains(lowerConsole, 'invoking target language compiler') || ...
        contains(lowerConsole, 'tlc code generation complete');
    compileConsole = contains(lowerConsole, 'compiling') || ...
        contains(lowerConsole, '### compiling');
    linkConsole = contains(lowerConsole, 'linking') || ...
        contains(lowerConsole, '### linking');
    [executablePath, executableHash] = localExecutableIdentity(buildRoot);

    evidence = localEmptyBuildEvidence();
    evidence.ScenarioID = scenarioID;
    evidence.CodeGenerationOccurred = codeChanged || codeConsole;
    evidence.CompilationOccurred = compileChanged || compileConsole;
    evidence.RelinkOccurred = linkChanged || linkConsole;
    evidence.SILBuildExecutionElapsed_s = elapsed;
    evidence.ChangedArtifactCount = numel(changed);
    evidence.ChangedArtifacts = strjoin(changed, '; ');
    evidence.ExecutablePath = executablePath;
    evidence.ExecutableSHA256 = executableHash;
    if evidence.CodeGenerationOccurred || evidence.CompilationOccurred || ...
            evidence.RelinkOccurred
        evidence.ReuseClassification = "BUILD_ACTIVITY_OBSERVED";
    else
        evidence.ReuseClassification = "GENERATED_ARTIFACTS_REUSED";
    end
end

function changed = localChangedPaths(before, after)
    changed = strings(0, 1);
    beforePaths = string({before.relative_path});
    for index = 1:numel(after)
        path = after(index).relative_path;
        beforeIndex = find(beforePaths == path, 1, 'first');
        if isempty(beforeIndex) || ...
                before(beforeIndex).bytes ~= after(index).bytes || ...
                before(beforeIndex).datenum ~= after(index).datenum
            changed(end + 1, 1) = path; %#ok<AGROW>
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
    executables = dir(fullfile(buildRoot, '**', '*.exe'));
    if isempty(executables)
        pathValue = "NOT_FOUND";
        hashValue = "NOT_FOUND";
        return;
    end
    [~, newestIndex] = max([executables.datenum]);
    pathValue = string(fullfile(executables(newestIndex).folder, ...
        executables(newestIndex).name));
    hashValue = localFileSha256(pathValue);
end

function [occurred, unsupported, classification] = ...
        localWarningEvidence(normalConsole, silConsole, ...
        normalWarning, silWarning, requiredOutputsCollected)
    combined = lower(string(normalConsole) + newline + ...
        string(silConsole) + newline + string(normalWarning) + ...
        newline + string(silWarning));
    unsupported = contains(combined, ...
        "unsupported sample time: continuous");
    occurred = strlength(string(normalWarning)) > 0 || ...
        strlength(string(silWarning)) > 0 || ...
        contains(combined, "warning:") || contains(combined, "warning ");
    if unsupported && requiredOutputsCollected
        classification = "LEGACY_OR_INTERNAL_LOGGING_ONLY";
    elseif unsupported
        classification = "REQUIRED_ROOT_OUTPUT_COLLECTION_IMPACTED";
    elseif occurred
        classification = "OTHER_WARNING";
    else
        classification = "NONE";
    end
end

function localWriteBuildEvidence(filePath, evidenceTable)
    fileIdentifier = fopen(filePath, 'wt');
    assert(fileIdentifier >= 0, 'Could not open build evidence file.');
    closeFile = onCleanup(@() fclose(fileIdentifier));
    fprintf(fileIdentifier, ['Build/reuse evidence is based on generated ', ...
        'artifact creation/modification and captured build console text.\n']);
    fprintf(fileIdentifier, ['Build-only wall time is not separately ', ...
        'exposed by the R2023b sim() call; elapsed values include top-model ', ...
        'SIL build orchestration and execution.\n\n']);
    for index = 1:height(evidenceTable)
        row = evidenceTable(index, :);
        fprintf(fileIdentifier, '%s\n', row.ScenarioID);
        fprintf(fileIdentifier, '  Code generation occurred: %d\n', ...
            row.CodeGenerationOccurred);
        fprintf(fileIdentifier, '  Compilation occurred: %d\n', ...
            row.CompilationOccurred);
        fprintf(fileIdentifier, '  Relink occurred: %d\n', ...
            row.RelinkOccurred);
        fprintf(fileIdentifier, '  Classification: %s\n', ...
            row.ReuseClassification);
        fprintf(fileIdentifier, '  SIL build+execution elapsed s: %.17g\n', ...
            row.SILBuildExecutionElapsed_s);
        fprintf(fileIdentifier, '  Executable: %s\n', row.ExecutablePath);
        fprintf(fileIdentifier, '  Executable SHA-256: %s\n', ...
            row.ExecutableSHA256);
        fprintf(fileIdentifier, '  Changed artifacts (%d): %s\n\n', ...
            row.ChangedArtifactCount, row.ChangedArtifacts);
        if row.ReuseClassification == "GENERATED_ARTIFACTS_REUSED"
            fprintf(fileIdentifier, ['  Evidence interpretation: no ', ...
                'code generation, compilation, or relink was observed; ', ...
                'the executable checksum records reuse.\n\n']);
        elseif row.ScenarioID == "SIL-CHAR-001"
            fprintf(fileIdentifier, ['  Evidence interpretation: ', ...
                'initial full code generation, compilation, and link.\n\n']);
        elseif row.ScenarioID == "SIL-CHAR-003"
            fprintf(fileIdentifier, ['  Evidence interpretation: ', ...
                'the change from 1 s to the frozen 4 s reversal run ', ...
                'coincided with code generation, compilation, relink, ', ...
                'and an executable checksum change.\n\n']);
        end
    end
    clear closeFile;
end

function localWriteMetadata(filePath, protocolVersion, overallStatus, ...
        sourceFile, derivedFile, sourceHashBefore, sourceHashAfter, ...
        derivedHashBefore, derivedHashAfter, parameters, buildRoot, ...
        summaryTable, integrityOK)
    fileIdentifier = fopen(filePath, 'wt');
    assert(fileIdentifier >= 0, 'Could not open metadata file.');
    closeFile = onCleanup(@() fclose(fileIdentifier));
    simulinkInfo = ver('simulink');
    fprintf(fileIdentifier, 'Protocol: %s\n', protocolVersion);
    fprintf(fileIdentifier, 'Phase: A Characterization\n');
    fprintf(fileIdentifier, 'Overall execution status: %s\n', overallStatus);
    fprintf(fileIdentifier, ['No numerical equivalence tolerance or ', ...
        'equivalence PASS/FAIL is defined.\n']);
    fprintf(fileIdentifier, 'MATLAB release: %s\n', version('-release'));
    fprintf(fileIdentifier, 'Simulink version: %s\n', simulinkInfo.Version);
    fprintf(fileIdentifier, 'Host platform: %s\n', computer('arch'));
    fprintf(fileIdentifier, 'Compiler/toolchain: %s\n', ...
        localCompilerDescription());
    fprintf(fileIdentifier, 'SystemTargetFile: grt.tlc\n');
    fprintf(fileIdentifier, 'Solver / FixedStep: ode4 / ts\n');
    fprintf(fileIdentifier, 'Kps/Kis/Kas/Vdc/ts: %.17g / %.17g / %.17g / %.17g / %.17g\n', ...
        parameters.Kps, parameters.Kis, parameters.Kas, ...
        parameters.Vdc, parameters.ts);
    fprintf(fileIdentifier, 'Source model: %s\n', sourceFile);
    fprintf(fileIdentifier, 'Source SHA before/after: %s / %s\n', ...
        sourceHashBefore, sourceHashAfter);
    fprintf(fileIdentifier, 'Derived model: %s\n', derivedFile);
    fprintf(fileIdentifier, 'Derived SHA before/after: %s / %s\n', ...
        derivedHashBefore, derivedHashAfter);
    fprintf(fileIdentifier, 'Integrity check: %d\n', integrityOK);
    fprintf(fileIdentifier, 'Build artifact root: %s\n', buildRoot);
    fprintf(fileIdentifier, ['Observation: yout Dataset Outport 1 = ', ...
        'sampled_Vcmd; Outport 2 = sampled_MotorSpeed.\n']);
    fprintf(fileIdentifier, ['Continuous internal signal logging was ', ...
        'disabled and was not used as required SIL observation.\n']);
    for index = 1:height(summaryTable)
        fprintf(fileIdentifier, '%s status: %s\n', ...
            summaryTable.ScenarioID(index), summaryTable.Status(index));
    end
    fprintf(fileIdentifier, 'Execution timestamp: %s\n', char(datetime( ...
        'now', 'TimeZone', 'local', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ssXXX')));
    clear closeFile;
end

function row = localEmptySummary()
    row = struct('ProtocolVersion', "", 'ScenarioID', "", ...
        'SourceScenario', "", 'InputDescription', "", ...
        'Status', "EXECUTION_ERROR", ...
        'NormalExecutionSuccess', false, ...
        'SILExecutionSuccess', false, ...
        'NormalSampleCount', NaN, 'SILSampleCount', NaN, ...
        'NormalStartTime_s', NaN, 'NormalStopTime_s', NaN, ...
        'SILStartTime_s', NaN, 'SILStopTime_s', NaN, ...
        'TimeGridEqual', false, ...
        'CodeGenerationOccurred', false, ...
        'CompilationOccurred', false, 'RelinkOccurred', false, ...
        'NormalElapsed_s', NaN, ...
        'SILBuildExecutionElapsed_s', NaN, ...
        'WarningOccurred', false, ...
        'UnsupportedContinuousWarning', false, ...
        'WarningClassification', "NONE", ...
        'NormalWarningIdentifier', "", 'NormalWarningText', "", ...
        'SILWarningIdentifier', "", 'SILWarningText', "", ...
        'ErrorIdentifier', "", 'ErrorMessage', "");
end

function row = localEmptyMetric()
    row = struct('ScenarioID', "", 'SignalName', "", 'Unit', "", ...
        'Status', "NOT_EVALUATED", 'SampleCount', NaN, ...
        'MaxAbsDiff', NaN, 'RmsDiff', NaN, ...
        'DifferingSampleCount', NaN, ...
        'FirstDifferingIndex', NaN, 'FirstDifferingTime_s', NaN, ...
        'TimeOfMaxDiff_s', NaN, ...
        'NormalFirstSample', NaN, 'NormalLastSample', NaN, ...
        'SILFirstSample', NaN, 'SILLastSample', NaN, ...
        'SaturationSampleCount', NaN, ...
        'SaturationFirstTime_s', NaN, ...
        'SaturationLastTime_s', NaN, ...
        'SaturationMaxAbsDiff', NaN, ...
        'TransitionWindowMaxAbsDiff', NaN, ...
        'NormalFirstNegativeTime_s', NaN, ...
        'SILFirstNegativeTime_s', NaN, 'Notes', "");
end

function row = localEmptyBuildEvidence()
    row = struct('ScenarioID', "", ...
        'CodeGenerationOccurred', false, ...
        'CompilationOccurred', false, 'RelinkOccurred', false, ...
        'ReuseClassification', "NOT_EVALUATED", ...
        'SILBuildExecutionElapsed_s', NaN, ...
        'ChangedArtifactCount', NaN, 'ChangedArtifacts', "", ...
        'ExecutablePath', "NOT_FOUND", ...
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
    assert(strcmp(get_param([modelName, '/sampled_Vcmd'], ...
        'BlockType'), 'Outport'));
    assert(strcmp(get_param([modelName, '/sampled_Vcmd'], 'Port'), '1'));
    assert(strcmp(get_param([modelName, '/sampled_MotorSpeed'], ...
        'BlockType'), 'Outport'));
    assert(strcmp(get_param([modelName, '/sampled_MotorSpeed'], ...
        'Port'), '2'));
    assert(strcmp(get_param([modelName, '/Observe_Vcmd_ZOH'], ...
        'BlockType'), 'ZeroOrderHold'));
    assert(strcmp(get_param([modelName, '/Observe_MotorSpeed_ZOH'], ...
        'BlockType'), 'ZeroOrderHold'));
end

function localAssertFrozenParameters(parameters)
    expectedKps = (2 * pi * 40) / 2185.96;
    expectedKis = 17.76 * expectedKps;
    assert(parameters.ts == 0.0004);
    assert(parameters.Vdc == 12);
    assert(parameters.Kps == expectedKps);
    assert(parameters.Kis == expectedKis);
    assert(parameters.Kas == expectedKis / expectedKps);
end

function localAssertFrozenScenarioDefinitions(manualFile, reversalFile)
    manualSource = string(regexprep(fileread(manualFile), '\s+', ' '));
    reversalSource = string(regexprep(fileread(reversalFile), '\s+', ' '));
    manualAnchors = [ ...
        "constantReferences = [16.75; -16.75; 2; -2; 15; -15];"; ...
        "constantReferences(runIndex), 1);" ];
    reversalAnchors = [ ...
        "addParameter(parser, 'SwitchingTime_s', 2, @localPositiveScalar);"; ...
        "addParameter(parser, 'StopTime_s', 4, @localPositiveScalar);"; ...
        "initial_reference_rps = [15; -15];"; ...
        "reversed_reference_rps = -initial_reference_rps;" ];
    localAssertAnchors(manualSource, manualAnchors, manualFile);
    localAssertAnchors(reversalSource, reversalAnchors, reversalFile);
end

function localAssertAnchors(source, anchors, filePath)
    for index = 1:numel(anchors)
        assert(contains(source, anchors(index)), ...
            'run_sil_b2b_characterization:FrozenDefinitionChanged', ...
            'Frozen definition changed in %s. Missing: %s', ...
            filePath, anchors(index));
    end
end

function localRelocateGeneratedRuntimeMat( ...
        generatedMatFile, existedBefore, buildRoot, scenarioID)
    if existedBefore || ~isfile(generatedMatFile)
        return;
    end
    runtimeDirectory = fullfile(buildRoot, 'runtime_output');
    localEnsureDirectory(runtimeDirectory);
    destination = fullfile(runtimeDirectory, ...
        sprintf('%s_%s.mat', erase(string(scenarioID), '-'), ...
        'runtime_output'));
    if isfile(destination)
        timestamp = char(datetime('now', ...
            'Format', 'yyyyMMdd_HHmmss_SSS'));
        destination = fullfile(runtimeDirectory, ...
            sprintf('%s_%s.mat', erase(string(scenarioID), '-'), ...
            timestamp));
    end
    [moved, message] = movefile(generatedMatFile, destination);
    assert(moved, ...
        'run_sil_b2b_characterization:RuntimeMatRelocationFailed', ...
        'Could not move generated runtime MAT file: %s', message);
end

function description = localCompilerDescription()
    description = "NOT_CONFIGURED";
    try
        configurations = mex.getCompilerConfigurations('C', 'Selected');
        if ~isempty(configurations)
            configuration = configurations(1);
            description = string(configuration.Name);
            if strlength(string(configuration.Version)) > 0
                description = description + " " + ...
                    string(configuration.Version);
            end
        end
    catch exception
        description = "UNAVAILABLE: " + string(exception.identifier);
    end
end

function localRestoreFileGeneration(originalConfig)
    Simulink.fileGenControl('set', ...
        'CacheFolder', originalConfig.CacheFolder, ...
        'CodeGenFolder', originalConfig.CodeGenFolder, ...
        'CodeGenFolderStructure', originalConfig.CodeGenFolderStructure);
end

function localRestoreModelLoadState(modelName, wasLoaded)
    if ~bdIsLoaded(modelName)
        return;
    end
    if ~strcmp(get_param(modelName, 'Dirty'), 'off')
        warning('run_sil_b2b_characterization:DirtyModelLeftOpen', ...
            'Derived model became dirty and was left open without saving.');
        return;
    end
    if ~wasLoaded
        close_system(modelName, 0);
    end
end

function localAssertFile(filePath, description)
    assert(isfile(filePath), ...
        'run_sil_b2b_characterization:MissingFile', ...
        '%s not found: %s', description, filePath);
end

function localEnsureDirectory(directoryPath)
    if ~isfolder(directoryPath)
        [created, message] = mkdir(directoryPath);
        assert(created, ...
            'run_sil_b2b_characterization:DirectoryCreationFailed', ...
            'Could not create directory %s: %s', directoryPath, message);
    end
end

function hashValue = localFileSha256(filePath)
    fileIdentifier = fopen(filePath, 'rb');
    assert(fileIdentifier >= 0, 'Could not open file for hashing: %s', ...
        filePath);
    closeFile = onCleanup(@() fclose(fileIdentifier));
    bytes = fread(fileIdentifier, Inf, '*uint8');
    clear closeFile;
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(typecast(bytes(:), 'int8'));
    digestBytes = typecast(digest.digest(), 'uint8');
    hashValue = upper(string(reshape(dec2hex( ...
        digestBytes, 2).', 1, [])));
end

function value = localOneLine(value)
    value = replace(string(value), [newline, char(13)], " ");
    value = strtrim(value);
end
