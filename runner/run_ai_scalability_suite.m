function [summaryTable, segmentTable, runData] = run_ai_scalability_suite(varargin)
%RUN_AI_SCALABILITY_SUITE Execute the frozen scalability MIL candidates.
%
%   RUN_AI_SCALABILITY_SUITE('Execute', false) performs dependency and
%   configuration preflight only. No simulation is performed.
%
%   CandidateIDs may select a stable ordered subset. It is used by the
%   mutation runner to execute only Test Cases that passed the healthy run.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'Execute', true, ...
        @(x) islogical(x) && isscalar(x));
    addParameter(parser, 'MutationID', "BASELINE", ...
        @(x) (isstring(x) || ischar(x)) && isscalar(string(x)));
    addParameter(parser, 'WriteResults', true, ...
        @(x) islogical(x) && isscalar(x));
    addParameter(parser, 'BaselineSegmentResults', table(), @istable);
    addParameter(parser, 'CandidateIDs', strings(0, 1), ...
        @(x) isstring(x) || iscellstr(x) || ischar(x));
    addParameter(parser, 'RunID', "", ...
        @(x) (isstring(x) || ischar(x)) && isscalar(string(x)));
    parse(parser, varargin{:});

    executeSuite = parser.Results.Execute;
    mutationID = upper(string(parser.Results.MutationID));
    writeResults = parser.Results.WriteResults;
    baselineSegmentResults = parser.Results.BaselineSegmentResults;
    candidateIDs = string(parser.Results.CandidateIDs(:));
    runID = string(parser.Results.RunID);
    if strlength(runID) == 0
        runID = localCreateRunID("SCALABILITY");
    end
    localValidateMutationID(mutationID);
    if mutationID ~= "BASELINE"
        assert(~isempty(baselineSegmentResults), ...
            'run_ai_scalability_suite:MissingBaselineAdjudication', ...
            ['Mutant execution requires healthy segment results with ', ...
             'frozen Tracking applicability.']);
    end

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    oracleDirectory = fullfile(runnerDirectory, 'oracles');
    resultDirectory = fullfile( ...
        repositoryRoot, 'results', 'scalability_extension_v1');
    modelName = 'AS2308_MIL_Baseline_v3';
    modelFile = fullfile(repositoryRoot, 'model', [modelName, '.slx']);
    poolFile = fullfile(resultDirectory, 'candidate_pool_frozen.csv');
    specificationFile = fullfile( ...
        resultDirectory, 'candidate_execution_spec_resolved.csv');
    healthyFile = fullfile(resultDirectory, 'healthy_execution_results.csv');
    healthySegmentFile = fullfile( ...
        resultDirectory, 'healthy_segment_results.csv');

    localAssertFile(modelFile, 'Baseline model');
    localAssertFile(poolFile, 'Frozen scalability candidate pool');
    localAssertFile(specificationFile, 'Resolved scalability execution spec');
    localAssertFile(fullfile(oracleDirectory, 'evaluate_direction.m'), ...
        'Direction Oracle');
    localAssertFile(fullfile(oracleDirectory, 'evaluate_tracking.m'), ...
        'Tracking Oracle');
    localAssertFile(fullfile(oracleDirectory, 'evaluate_voltage_limit.m'), ...
        'Voltage Oracle');
    localAssertFile(fullfile(runnerDirectory, ...
        'scalability_stimulus_harness.m'), 'Scalability stimulus harness');
    addpath(oracleDirectory);

    parameters = localProjectParameters();
    specification = localReadTextTable(specificationFile);
    pool = localReadTextTable(poolFile);
    localValidateSpecification(specification, pool, parameters);
    if ~isempty(candidateIDs)
        assert(numel(unique(candidateIDs)) == numel(candidateIDs), ...
            'run_ai_scalability_suite:DuplicateCandidateFilter', ...
            'CandidateIDs must not contain duplicates.');
        unknown = setdiff(candidateIDs, specification.extension_candidate_id);
        assert(isempty(unknown), ...
            'run_ai_scalability_suite:UnknownCandidateFilter', ...
            'CandidateIDs contains unknown IDs: %s', strjoin(unknown, ', '));
        selected = ismember(specification.extension_candidate_id, candidateIDs);
        specification = specification(selected, :);
    end

    if ~isfolder(resultDirectory)
        mkdir(resultDirectory);
    end
    assert(isfolder(resultDirectory), ...
        'run_ai_scalability_suite:ResultDirectoryCreationFailed', ...
        'Could not create result directory: %s', resultDirectory);

    sourceModelName = modelName;
    harness = scalability_stimulus_harness('create', modelFile, parameters.ts);
    cleanupHarness = onCleanup(@() localFinalizeHarness( ...
        harness, modelFile)); %#ok<NASGU>
    modelName = char(harness.model_name);
    localValidateStoredModelConfiguration(modelName, parameters.ts);
    stimulus = localStimulusBlocks(modelName);

    fprintf('\nAI Scalability MIL Suite preflight\n');
    fprintf('Source model: %s\n', sourceModelName);
    fprintf('Runtime harness: %s\n', modelName);
    fprintf('Runtime mutation: %s\n', mutationID);
    fprintf('Frozen pool candidates: %d\n', height(pool));
    fprintf('Selected executions: %d\n', height(specification));
    fprintf('Frozen pool hash: %s\n', specification.frozen_pool_sha256(1));
    fprintf('Output directory: %s\n', resultDirectory);
    fprintf('Preflight: PASS\n');

    if ~executeSuite
        summaryTable = table();
        segmentTable = table();
        runData = struct( ...
            'preflight_pass', true, ...
            'candidate_count', height(specification), ...
            'frozen_pool_hash', specification.frozen_pool_sha256(1), ...
            'result_directory', string(resultDirectory), ...
            'stimulus_harness', "GENERIC_FROM_WORKSPACE_ZOH", ...
            'simulation_executed', false);
        fprintf('Simulation executed: false\n\n');
        return;
    end

    incompleteSummaryFile = fullfile(resultDirectory, ...
        "healthy_execution_results_incomplete_" + runID + ".csv");
    incompleteSegmentFile = fullfile(resultDirectory, ...
        "healthy_segment_results_incomplete_" + runID + ".csv");
    if writeResults && mutationID == "BASELINE"
        assert(~isfile(healthyFile) && ~isfile(healthySegmentFile) && ...
            ~isfile(incompleteSummaryFile) && ~isfile(incompleteSegmentFile), ...
            'run_ai_scalability_suite:ExistingHealthyResult', ...
            'Refusing to overwrite existing complete or incomplete healthy results.');
    end

    summaryRows = repmat(localEmptySummaryRow(), 0, 1);
    segmentRows = repmat(localEmptySegmentRow(), 0, 1);
    runData = repmat(struct( ...
        'extension_candidate_id', "", 'status', "", ...
        'samples', table(), 'error_message', ""), height(specification), 1);

    for rowIndex = 1:height(specification)
        specRow = specification(rowIndex, :);
        candidateID = specRow.extension_candidate_id;
        fprintf('\n[%d/%d] %s\n', rowIndex, height(specification), candidateID);
        executionTimer = tic;
        try
            values = localParseValues(specRow.original_input_values, candidateID);
            [signals, samples] = localSimulateCandidate( ...
                modelName, specRow, values, parameters, stimulus, mutationID);
            [summaryRow, newSegmentRows] = localEvaluateCandidate( ...
                specRow, values, signals, parameters, mutationID, ...
                baselineSegmentResults);
            runData(rowIndex).extension_candidate_id = candidateID;
            runData(rowIndex).status = summaryRow.status;
            runData(rowIndex).samples = samples;
            runData(rowIndex).error_message = "";
        catch exception
            summaryRow = localErrorSummaryRow(specRow, exception);
            newSegmentRows = localErrorSegmentRows(specRow, exception);
            runData(rowIndex).extension_candidate_id = candidateID;
            runData(rowIndex).status = "EXECUTION_ERROR";
            runData(rowIndex).samples = table();
            runData(rowIndex).error_message = string(exception.message);
        end
        summaryRow.run_id = runID;
        summaryRow.elapsed_time_s = toc(executionTimer);
        for segmentIndex = 1:numel(newSegmentRows)
            newSegmentRows(segmentIndex).run_id = runID;
        end
        summaryRows(end + 1, 1) = summaryRow; %#ok<AGROW>
        segmentRows = [segmentRows; newSegmentRows]; %#ok<AGROW>
        if writeResults && mutationID == "BASELINE"
            writetable(struct2table(summaryRows), incompleteSummaryFile);
            writetable(struct2table(segmentRows), incompleteSegmentFile);
        end
        fprintf('Status: %s | elapsed %.6g s\n', ...
            summaryRow.status, summaryRow.elapsed_time_s);
    end

    summaryTable = struct2table(summaryRows);
    segmentTable = struct2table(segmentRows);
    if writeResults && mutationID == "BASELINE"
        writetable(summaryTable, healthyFile);
        writetable(segmentTable, healthySegmentFile);
        fprintf('Healthy results: %s\n', healthyFile);
    elseif writeResults
        error('run_ai_scalability_suite:MutantWriteNotAllowed', ...
            'Mutant runs are written only by the scalability mutation runner.');
    end
end

function tableValue = localReadTextTable(path)
    options = detectImportOptions(path, 'TextType', 'string');
    options = setvartype(options, options.VariableNames, 'string');
    tableValue = readtable(path, options);
    numericNames = intersect(options.VariableNames, { ...
        'selection_order', 'segment_count', 'segment_duration_s', ...
        'total_duration_s', 'sample_time_s', 'evaluation_window_s'});
    for index = 1:numel(numericNames)
        name = numericNames{index};
        tableValue.(name) = str2double(tableValue.(name));
    end
end

function parameters = localProjectParameters()
    parameters = struct( ...
        'port_num', 7, 'ts', 0.0004, 'Vdc', 12, 'cpr', 4096, ...
        'horizon', 20, 'pole_pair', 7, 'a', 17.76, 'b', 2185.96, ...
        'f_cs', 40);
    parameters.w_cs = 2 * pi * parameters.f_cs;
    parameters.Kps = parameters.w_cs / parameters.b;
    parameters.Kis = parameters.a * parameters.Kps;
    parameters.Kas = parameters.Kis / parameters.Kps;
    parameters.f_cp = parameters.f_cs / 5;
    parameters.w_cp = 2 * pi * parameters.f_cp;
    parameters.Kpp = parameters.w_cp;
end

function localValidateSpecification(specification, pool, parameters)
    required = [ ...
        "selection_order", "extension_candidate_id", "requirement_id", ...
        "test_scope", "waveform_type", "original_input_values", ...
        "segment_count", "segment_duration_s", "total_duration_s", ...
        "sample_time_s", "oracle_mapping", "evaluation_window_s", ...
        "frozen_pool_sha256"];
    assert(all(ismember(required, string(specification.Properties.VariableNames))), ...
        'run_ai_scalability_suite:MissingSpecificationColumn', ...
        'Resolved execution specification is missing required columns.');
    poolRequired = ["selection_order", "extension_candidate_id", ...
        "requirement_id", "frozen_pool_sha256"];
    assert(all(ismember(poolRequired, string(pool.Properties.VariableNames))), ...
        'run_ai_scalability_suite:MissingPoolColumn', ...
        'Frozen candidate pool is missing required columns.');
    assert(height(specification) == 100 && height(pool) == 100, ...
        'run_ai_scalability_suite:UnexpectedCandidateCount', ...
        'Frozen pool and execution spec must each contain exactly 100 rows.');
    expectedOrder = (1:100)';
    assert(isequal(specification.selection_order, expectedOrder) && ...
        isequal(pool.selection_order, expectedOrder), ...
        'run_ai_scalability_suite:InvalidSelectionOrder', ...
        'selection_order must be the ordered integers 1 through 100.');
    assert(isequal(specification.extension_candidate_id, ...
        pool.extension_candidate_id), ...
        'run_ai_scalability_suite:PoolSpecificationMismatch', ...
        'Frozen pool and execution spec candidate order differ.');
    assert(isequal(specification.requirement_id, pool.requirement_id), ...
        'run_ai_scalability_suite:PoolRequirementMismatch', ...
        'Frozen pool and execution spec Requirement IDs differ.');
    hashes = unique([specification.frozen_pool_sha256; pool.frozen_pool_sha256]);
    assert(numel(hashes) == 1 && strlength(hashes) > 0, ...
        'run_ai_scalability_suite:PoolHashMismatch', ...
        'Frozen pool hash is missing or inconsistent.');
    assert(all(specification.segment_duration_s == 2.0), ...
        'run_ai_scalability_suite:UnexpectedSegmentDuration', ...
        'Every segment must use the frozen 2.0 s duration.');
    assert(all(specification.sample_time_s == parameters.ts), ...
        'run_ai_scalability_suite:UnexpectedSampleTime', ...
        'Every row must use ts = %.17g s.', parameters.ts);
    assert(numel(unique(specification.extension_candidate_id)) == 100, ...
        'run_ai_scalability_suite:DuplicateCandidate', ...
        'extension_candidate_id values must be unique.');
    for rowIndex = 1:height(specification)
        values = localParseValues(specification.original_input_values(rowIndex), ...
            specification.extension_candidate_id(rowIndex));
        assert(numel(values) == specification.segment_count(rowIndex), ...
            'run_ai_scalability_suite:SegmentCountMismatch', ...
            'segment_count differs from input_values for %s.', ...
            specification.extension_candidate_id(rowIndex));
        expectedDuration = numel(values) * ...
            specification.segment_duration_s(rowIndex);
        assert(abs(expectedDuration - specification.total_duration_s(rowIndex)) ...
            <= 64 * eps(max(1, expectedDuration)), ...
            'run_ai_scalability_suite:DurationMismatch', ...
            'total_duration_s is inconsistent for %s.', ...
            specification.extension_candidate_id(rowIndex));
        profile = scalability_stimulus_harness('profile', values, ...
            specification.segment_duration_s(rowIndex));
        assert(height(profile) == specification.segment_count(rowIndex), ...
            'run_ai_scalability_suite:ProfileResolutionFailure', ...
            'Generic stimulus profile resolution failed for %s.', ...
            specification.extension_candidate_id(rowIndex));
    end
end

function localValidateStoredModelConfiguration(modelName, ts)
    assert(strcmp(get_param(modelName, 'SolverType'), 'Fixed-step'));
    assert(strcmp(get_param(modelName, 'Solver'), 'ode4'));
    assert(strcmp(get_param(modelName, 'FixedStep'), 'ts'));
    assert(ts == 0.0004);
end

function stimulus = localStimulusBlocks(modelName)
    stimulus = struct( ...
        'source', [modelName, '/Scalability SpeedRef Source'], ...
        'switch', [modelName, '/Manual Switch'], ...
        'downstreamSwitch', [modelName, '/Manual Switch3']);
    assert(strcmp(get_param(stimulus.source, 'BlockType'), 'FromWorkspace'));
    assert(strcmp(get_param(stimulus.source, 'Interpolate'), 'off'));
    assert(strcmp(get_param(stimulus.source, 'SampleTime'), 'ts'));
end

function values = localParseValues(jsonText, candidateID)
    values = double(jsondecode(char(jsonText)));
    values = values(:)';
    assert(~isempty(values) && all(isfinite(values)), ...
        'run_ai_scalability_suite:InvalidInputValues', ...
        'original_input_values must be finite for %s.', candidateID);
end

function [signals, samples] = localSimulateCandidate( ...
        modelName, specRow, values, parameters, stimulus, mutationID)
    simulationInput = Simulink.SimulationInput(modelName);
    names = fieldnames(parameters);
    for index = 1:numel(names)
        simulationInput = simulationInput.setVariable( ...
            names{index}, parameters.(names{index}));
    end
    profile = scalability_stimulus_harness('profile', values, ...
        specRow.segment_duration_s);
    simulationInput = simulationInput.setVariable( ...
        'scalabilitySpeedRefProfile', profile);
    simulationInput = localApplyFrozenMutation( ...
        simulationInput, modelName, mutationID, parameters.Kis);
    simulationInput = simulationInput.setBlockParameter( ...
        stimulus.downstreamSwitch, 'CurrentSetting', '0');
    simulationInput = simulationInput.setBlockParameter( ...
        stimulus.switch, 'CurrentSetting', '0');
    simulationInput = simulationInput.setModelParameter( ...
        'StopTime', sprintf('%.17g', specRow.total_duration_s), ...
        'SignalLogging', 'on', 'SignalLoggingName', 'logsout', ...
        'SignalLoggingSaveFormat', 'Dataset', 'ReturnWorkspaceOutputs', 'on');
    output = sim(simulationInput);
    logsout = output.get('logsout');
    assert(isa(logsout, 'Simulink.SimulationData.Dataset'), ...
        'run_ai_scalability_suite:MissingLogsout', ...
        'Expected logsout Dataset was not produced.');
    referenceSignal = localGetLoggedSignal(logsout, 'reference');
    speedSignal = localGetLoggedSignal(logsout, 'motorspeed');
    vcmdSignal = localGetLoggedSignal(logsout, 'Vcmd');
    rawSignal = localGetLoggedSignal(logsout, 'raw_pi_output');
    time = double(speedSignal.Time(:));
    motorspeed = double(squeeze(speedSignal.Data));
    motorspeed = motorspeed(:);
    reference = localAlignSignal(referenceSignal, time);
    vcmd = localAlignSignal(vcmdSignal, time);
    rawPi = localAlignSignal(rawSignal, time);
    if numel(values) > 1
        requested = time < specRow.total_duration_s;
        time = time(requested); reference = reference(requested);
        motorspeed = motorspeed(requested); vcmd = vcmd(requested);
        rawPi = rawPi(requested);
    end
    assert(all(isfinite(time)) && all(isfinite(reference)) && ...
        all(isfinite(motorspeed)) && all(isfinite(vcmd)) && ...
        all(isfinite(rawPi)) && all(diff(time) > 0), ...
        'run_ai_scalability_suite:InvalidSignals', ...
        'Logged signals must be finite with strictly increasing time.');
    localVerifyWaveform(time, reference, values, ...
        specRow.segment_duration_s, specRow.total_duration_s);
    signals = struct('time', time, 'reference', reference, ...
        'motorspeed', motorspeed, 'vcmd', vcmd, 'raw_pi_output', rawPi);
    samples = table(time, reference, motorspeed, vcmd, rawPi, ...
        'VariableNames', {'time_s', 'reference_rps', 'motorspeed_rps', ...
        'Vcmd_v', 'raw_pi_output_v'});
end

function simulationInput = localApplyFrozenMutation( ...
        simulationInput, modelName, mutationID, baselineKis)
    switch mutationID
        case "BASELINE"
            return;
        case "MUT-001"
            simulationInput = simulationInput.setVariable('Kis', 0);
        case "MUT-002"
            simulationInput = simulationInput.setVariable('Kis', -abs(baselineKis));
        case "MUT-003"
            simulationInput = simulationInput.setBlockParameter( ...
                [modelName, '/PI Speed Controller/Subtract'], 'Inputs', '++');
        case "MUT-004"
            simulationInput = simulationInput.setBlockParameter( ...
                [modelName, '/PI Speed Controller/Saturation'], 'UpperLimit', '13');
        case "MUT-005"
            simulationInput = simulationInput.setBlockParameter( ...
                [modelName, '/PI Speed Controller/Saturation'], 'LowerLimit', '-13');
        case "MUT-006"
            simulationInput = simulationInput.setBlockParameter( ...
                [modelName, '/PI Speed Controller/Saturation'], 'UpperLimit', '0');
    end
end

function [summaryRow, detailRows] = localEvaluateCandidate( ...
        specRow, values, signals, parameters, mutationID, baselineSegments)
    count = numel(values);
    detailRows = repmat(localEmptySegmentRow(), count, 1);
    required = strings(0, 1); applicabilityResults = strings(0, 1);
    plateauPass = false(count, 1); reversalSetup = "NOT_REQUIRED";
    fullVoltage = struct();
    if specRow.requirement_id == "REQ-VOLT-001"
        fullVoltage = evaluate_voltage_limit(signals.time, signals.vcmd, parameters.Vdc);
        required(end + 1, 1) = localPassFail(fullVoltage.pass);
    end
    previousSign = 0;
    for segmentIndex = 1:count
        startTime = (segmentIndex - 1) * specRow.segment_duration_s;
        endTime = segmentIndex * specRow.segment_duration_s;
        if segmentIndex < count
            rows = signals.time >= startTime & signals.time < endTime;
        else
            rows = signals.time >= startTime & signals.time <= specRow.total_duration_s;
        end
        assert(any(rows), 'run_ai_scalability_suite:EmptySegment', ...
            'No samples for segment %d.', segmentIndex);
        t = signals.time(rows); r = signals.reference(rows);
        speed = signals.motorspeed(rows); vcmd = signals.vcmd(rows);
        raw = signals.raw_pi_output(rows);
        detail = localEmptySegmentRow();
        detail.extension_candidate_id = specRow.extension_candidate_id;
        detail.segment_index = segmentIndex; detail.reference_rps = values(segmentIndex);
        detail.start_time_s = startTime; detail.end_time_s = endTime;
        if specRow.requirement_id == "REQ-DIR-001" && segmentIndex == count
            result = evaluate_direction(t, r, speed);
            detail.direction_result = localPassFail(result.pass);
            required(end + 1, 1) = detail.direction_result; %#ok<AGROW>
        elseif specRow.requirement_id == "REQ-TRK-001"
            if mutationID == "BASELINE"
                isPersistentClamp = localPersistentTerminalClamp( ...
                    t, raw, vcmd, parameters.Vdc, specRow.evaluation_window_s);
                if isPersistentClamp
                    frozen = "PRECONDITION_NOT_MET";
                else
                    frozen = "APPLICABLE";
                end
            else
                frozen = localFrozenApplicability( ...
                    baselineSegments, specRow.extension_candidate_id, segmentIndex);
            end
            detail.applicability = frozen;
            applicabilityResults(end + 1, 1) = frozen; %#ok<AGROW>
            if frozen == "PRECONDITION_NOT_MET"
                detail.tracking_result = "INCONCLUSIVE_PRECONDITION";
            else
                result = evaluate_tracking(t, r, speed);
                detail.tracking_result = localPassFail(result.pass);
                required(end + 1, 1) = detail.tracking_result; %#ok<AGROW>
            end
        elseif specRow.requirement_id == "REQ-REV-001"
            direction = evaluate_direction(t, r, speed);
            tracking = evaluate_tracking(t, r, speed);
            plateauPass(segmentIndex) = direction.pass && tracking.pass;
            detail.direction_result = localPassFail(direction.pass);
            detail.tracking_result = localPassFail(tracking.pass);
            currentSign = sign(values(segmentIndex));
            reversed = previousSign ~= 0 && currentSign ~= 0 && currentSign ~= previousSign;
            if segmentIndex == 1
                if plateauPass(segmentIndex)
                    reversalSetup = "ESTABLISHED"; detail.setup_status = "ESTABLISHED";
                else
                    reversalSetup = "NOT_ESTABLISHED"; detail.setup_status = "NOT_ESTABLISHED";
                end
            elseif reversed
                if ~plateauPass(segmentIndex - 1)
                    applicabilityResults(end + 1, 1) = "PRECONDITION_NOT_MET"; %#ok<AGROW>
                    detail.transition_result = "INCONCLUSIVE_PRECONDITION";
                elseif plateauPass(segmentIndex)
                    required(end + 1, 1) = "PASS"; %#ok<AGROW>
                    detail.transition_result = "PASS";
                else
                    required(end + 1, 1) = "FAIL"; %#ok<AGROW>
                    detail.transition_result = "FAIL";
                end
            end
            if currentSign ~= 0; previousSign = currentSign; end
        elseif specRow.requirement_id == "REQ-VOLT-001"
            segmentVoltage = evaluate_voltage_limit(t, vcmd, parameters.Vdc);
            detail.voltage_result = localPassFail(segmentVoltage.pass);
        end
        detailRows(segmentIndex) = detail;
    end
    noTracking = specRow.requirement_id == "REQ-TRK-001" && ...
        ~isempty(applicabilityResults) && ...
        all(applicabilityResults == "PRECONDITION_NOT_MET");
    noReversal = specRow.requirement_id == "REQ-REV-001" && ...
        ~isempty(applicabilityResults) && ...
        all(applicabilityResults == "PRECONDITION_NOT_MET");
    assert(~isempty(required) || noTracking || noReversal, ...
        'run_ai_scalability_suite:NoRequiredEvaluation', ...
        'No required Oracle result for %s.', specRow.extension_candidate_id);
    if any(required == "FAIL")
        status = "FAIL"; reason = "At least one required Oracle evaluation failed.";
    elseif any(applicabilityResults == "PRECONDITION_NOT_MET")
        status = "INCONCLUSIVE_PRECONDITION";
        reason = "A frozen applicability or reversal setup condition was not met.";
    else
        status = "PASS"; reason = "";
    end
    if specRow.requirement_id == "REQ-TRK-001"
        if all(applicabilityResults == "APPLICABLE")
            applicability = "APPLICABLE";
        elseif all(applicabilityResults == "PRECONDITION_NOT_MET")
            applicability = "PRECONDITION_NOT_MET";
        else
            applicability = "PARTIALLY_APPLICABLE";
        end
    elseif specRow.requirement_id == "REQ-REV-001" && ...
            any(applicabilityResults == "PRECONDITION_NOT_MET")
        applicability = "PRECONDITION_NOT_MET";
    else
        applicability = "NOT_REQUIRED";
    end
    summaryRow = localEmptySummaryRow();
    summaryRow.ordered_index = specRow.selection_order;
    summaryRow.extension_candidate_id = specRow.extension_candidate_id;
    summaryRow.requirement_id = specRow.requirement_id;
    summaryRow.test_scope = specRow.test_scope;
    summaryRow.waveform_type = specRow.waveform_type;
    summaryRow.status = status; summaryRow.applicability = applicability;
    summaryRow.reversal_setup_status = reversalSetup;
    summaryRow.failure_reason = reason;
    if specRow.requirement_id == "REQ-VOLT-001" && ~fullVoltage.pass
        summaryRow.failure_reason = sprintf( ...
            'Complete-interval Vcmd range [%+.17g, %+.17g] V exceeded limits.', ...
            fullVoltage.min_vcmd_v, fullVoltage.max_vcmd_v);
    end
end

function applicability = localFrozenApplicability(segments, candidateID, segmentIndex)
    rows = segments.extension_candidate_id == candidateID & ...
        segments.segment_index == segmentIndex;
    assert(sum(rows) == 1, ...
        'run_ai_scalability_suite:MissingFrozenApplicability', ...
        'Missing healthy applicability for %s segment %d.', candidateID, segmentIndex);
    applicability = segments.applicability(rows);
    assert(applicability == "APPLICABLE" || ...
        applicability == "PRECONDITION_NOT_MET");
end

function isPersistentClamp = localPersistentTerminalClamp(time, raw, vcmd, limit, window)
    rows = time >= time(end) - window;
    tolerance = 64 * eps(max([1; abs(vcmd(rows)); limit]));
    positive = raw(rows) > limit & abs(vcmd(rows) - limit) <= tolerance;
    negative = raw(rows) < -limit & abs(vcmd(rows) + limit) <= tolerance;
    isPersistentClamp = all(positive | negative);
end

function localVerifyWaveform(time, reference, values, duration, totalDuration)
    for index = 1:numel(values)
        startTime = (index - 1) * duration; endTime = index * duration;
        if index < numel(values)
            rows = time >= startTime & time < endTime;
        else
            rows = time >= startTime & time <= totalDuration;
        end
        assert(any(rows));
        tolerance = 64 * eps(max(1, abs(values(index))));
        assert(all(abs(reference(rows) - values(index)) <= tolerance), ...
            'run_ai_scalability_suite:WaveformMismatch', ...
            'Logged reference differs from segment %d.', index);
    end
end

function signal = localGetLoggedSignal(logsout, name)
    element = logsout.get(name);
    assert(~isempty(element), 'run_ai_scalability_suite:MissingSignal', ...
        'Logged signal "%s" was not found.', name);
    signal = element.Values;
end

function values = localAlignSignal(signal, targetTime)
    signalTime = double(signal.Time(:)); data = double(squeeze(signal.Data));
    data = data(:);
    if isequal(signalTime, targetTime)
        values = data;
    else
        values = interp1(signalTime, data, targetTime, 'previous', 'extrap');
    end
end

function row = localEmptySummaryRow()
    row = struct('run_id', "", 'ordered_index', NaN, ...
        'extension_candidate_id', "", 'requirement_id', "", ...
        'test_scope', "", 'waveform_type', "", 'status', "", ...
        'applicability', "NOT_REQUIRED", ...
        'reversal_setup_status', "NOT_REQUIRED", ...
        'elapsed_time_s', NaN, 'failure_reason', "");
end

function row = localEmptySegmentRow()
    row = struct('run_id', "", 'extension_candidate_id', "", ...
        'segment_index', NaN, 'reference_rps', NaN, ...
        'start_time_s', NaN, 'end_time_s', NaN, ...
        'applicability', "NOT_REQUIRED", 'setup_status', "NOT_REQUIRED", ...
        'transition_result', "NOT_EVALUATED", ...
        'direction_result', "NOT_EVALUATED", ...
        'tracking_result', "NOT_EVALUATED", ...
        'voltage_result', "NOT_EVALUATED");
end

function row = localErrorSummaryRow(specRow, exception)
    row = localEmptySummaryRow();
    row.ordered_index = specRow.selection_order;
    row.extension_candidate_id = specRow.extension_candidate_id;
    row.requirement_id = specRow.requirement_id;
    row.test_scope = specRow.test_scope;
    row.waveform_type = specRow.waveform_type;
    row.status = "EXECUTION_ERROR";
    row.applicability = "NOT_EVALUATED";
    row.failure_reason = string(exception.message);
end

function rows = localErrorSegmentRows(specRow, exception)
    rows = repmat(localEmptySegmentRow(), specRow.segment_count, 1);
    values = localParseValues(specRow.original_input_values, ...
        specRow.extension_candidate_id);
    for index = 1:specRow.segment_count
        rows(index).extension_candidate_id = specRow.extension_candidate_id;
        rows(index).segment_index = index;
        rows(index).reference_rps = values(index);
        rows(index).start_time_s = (index - 1) * specRow.segment_duration_s;
        rows(index).end_time_s = index * specRow.segment_duration_s;
        rows(index).applicability = "NOT_EVALUATED";
        rows(index).direction_result = "EXECUTION_ERROR";
        rows(index).tracking_result = "EXECUTION_ERROR";
        rows(index).voltage_result = "EXECUTION_ERROR";
        rows(index).transition_result = string(exception.message);
    end
end

function result = localPassFail(passValue)
    if passValue; result = "PASS"; else; result = "FAIL"; end
end

function localValidateMutationID(mutationID)
    allowed = ["BASELINE"; compose("MUT-%03d", (1:6).')];
    assert(any(mutationID == allowed), ...
        'run_ai_scalability_suite:UnknownMutation', ...
        'MutationID must be BASELINE or MUT-001 through MUT-006.');
end

function localAssertFile(path, description)
    assert(isfile(path), 'run_ai_scalability_suite:MissingDependency', ...
        '%s was not found: %s', description, path);
end

function localFinalizeHarness(harness, sourceFile)
    scalability_stimulus_harness('cleanup', harness);
    assert(localFileSha256(sourceFile) == harness.source_sha256, ...
        'run_ai_scalability_suite:SourceHashChanged', ...
        'Frozen baseline SHA-256 changed during harness use.');
end

function hash = localFileSha256(path)
    fid = fopen(path, 'rb');
    assert(fid >= 0, 'run_ai_scalability_suite:HashRead', ...
        'Cannot read file for SHA-256: %s', path);
    cleanup = onCleanup(@()fclose(fid)); %#ok<NASGU>
    bytes = fread(fid, Inf, '*uint8');
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(typecast(bytes, 'int8'));
    hash = upper(string(reshape( ...
        dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, [])));
end

function runID = localCreateRunID(prefix)
    runID = string(prefix) + "_" + string(datetime('now', ...
        'TimeZone', 'UTC', 'Format', 'yyyyMMdd''T''HHmmssSSS''Z'''));
end
