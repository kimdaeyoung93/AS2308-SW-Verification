function [summaryTable, segmentTable, runData] = run_ai_mil_suite(varargin)
%RUN_AI_MIL_SUITE Execute the frozen Official AI MIL Suite v1.
%
%   [SUMMARY, SEGMENTS, RUNDATA] = RUN_AI_MIL_SUITE() executes the nine
%   frozen AI candidates against AS2308_MIL_Baseline_v3 and writes:
%     results/ai_mil/AI_MIL_Suite_Summary.csv
%     results/ai_mil/AI_MIL_Segment_Results.csv
%
%   RUN_AI_MIL_SUITE('Execute', false) performs preflight checks only. It
%   validates dependencies, candidate count, waveform durations, stored
%   solver configuration, and output-directory creation without simulating.
%
%   The 2.0 s plateau duration and 0.05 s terminal window are frozen test
%   execution parameters, not product performance requirements. Existing
%   Oracle implementations and thresholds are reused without modification.
%
%   Top-level aggregation:
%     EXECUTION_ERROR              any simulation/data/Oracle error
%     FAIL                         any required applicable Oracle result FAIL
%     INCONCLUSIVE_PRECONDITION    no FAIL, but at least one REQ-TRK-001
%                                  plateau has persistent terminal clamp
%     PASS                         every required applicable result PASS

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'Execute', true, ...
        @(x) islogical(x) && isscalar(x));
    parse(parser, varargin{:});
    executeSuite = parser.Results.Execute;

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    modelDirectory = fullfile(repositoryRoot, 'model');
    oracleDirectory = fullfile(runnerDirectory, 'oracles');
    aiOutputDirectory = fullfile(repositoryRoot, 'ai', 'output');
    resultDirectory = fullfile(repositoryRoot, 'results', 'ai_mil');

    modelName = 'AS2308_MIL_Baseline_v3';
    modelFile = fullfile(modelDirectory, [modelName, '.slx']);
    specificationFile = fullfile( ...
        aiOutputDirectory, 'ai_suite_v1_resolved_execution_spec.csv');
    candidateFile = fullfile(aiOutputDirectory, 'ai_candidates.json');
    summaryFile = fullfile(resultDirectory, 'AI_MIL_Suite_Summary.csv');
    segmentFile = fullfile(resultDirectory, 'AI_MIL_Segment_Results.csv');

    localAssertFile(modelFile, 'Baseline model');
    localAssertFile(specificationFile, 'Resolved AI execution specification');
    localAssertFile(candidateFile, 'AI candidate source');
    localAssertFile(fullfile(oracleDirectory, 'evaluate_direction.m'), ...
        'Direction Oracle');
    localAssertFile(fullfile(oracleDirectory, 'evaluate_tracking.m'), ...
        'Tracking Oracle');
    localAssertFile(fullfile(oracleDirectory, 'evaluate_voltage_limit.m'), ...
        'Voltage Oracle');
    addpath(oracleDirectory);

    % Baseline project parameters. These values match the existing project
    % initialization and are applied per simulation through SimulationInput.
    parameters = localProjectParameters();

    importOptions = detectImportOptions( ...
        specificationFile, 'TextType', 'string');
    specification = readtable(specificationFile, importOptions);
    candidatePayload = jsondecode(fileread(candidateFile));
    candidateRecords = candidatePayload.candidates;
    localValidateSpecification(specification, candidateRecords, parameters);

    if ~isfolder(resultDirectory)
        mkdir(resultDirectory);
    end
    assert(isfolder(resultDirectory), ...
        'run_ai_mil_suite:ResultDirectoryCreationFailed', ...
        'Could not create results directory: %s', resultDirectory);

    modelWasLoaded = bdIsLoaded(modelName);
    load_system(modelFile);
    closeModel = onCleanup(@() localCloseModel(modelName, modelWasLoaded));
    localValidateStoredModelConfiguration(modelName, parameters.ts);
    stimulus = localStimulusBlocks(modelName);

    fprintf('\nOfficial AI MIL Suite v1 preflight\n');
    fprintf('Model: %s\n', modelName);
    fprintf('Recognized candidates: %d\n', height(specification));
    fprintf('Segment duration: %.6g s; sample time: %.6g s\n', ...
        unique(specification.segment_duration_s), parameters.ts);
    fprintf('Output directory: %s\n', resultDirectory);
    fprintf('Preflight: PASS\n');

    if ~executeSuite
        summaryTable = table();
        segmentTable = table();
        runData = struct( ...
            'preflight_pass', true, ...
            'candidate_count', height(specification), ...
            'result_directory', resultDirectory, ...
            'simulation_executed', false);
        fprintf('Simulation executed: false\n\n');
        return;
    end

    summaryRows = repmat(localEmptySummaryRow(), 0, 1);
    segmentRows = repmat(localEmptySegmentRow(), 0, 1);
    runData = repmat(struct( ...
        'candidate_id', "", ...
        'status', "", ...
        'samples', table(), ...
        'error_message', ""), height(specification), 1);

    for rowIndex = 1:height(specification)
        specRow = specification(rowIndex, :);
        candidateId = specRow.candidate_id;
        metadata = localCandidateMetadata(candidateRecords, candidateId);

        fprintf('\n[%d/%d] %s\n', rowIndex, height(specification), candidateId);
        try
            values = localParseValues(specRow.original_input_values, candidateId);
            [signals, samples] = localSimulateCandidate( ...
                modelName, specRow, values, parameters, stimulus);
            [summaryRow, newSegmentRows] = localEvaluateCandidate( ...
                specRow, metadata, values, signals, parameters);

            runData(rowIndex).candidate_id = candidateId;
            runData(rowIndex).status = summaryRow.status;
            runData(rowIndex).samples = samples;
            runData(rowIndex).error_message = "";
        catch exception
            summaryRow = localErrorSummaryRow(specRow, metadata, exception);
            newSegmentRows = localErrorSegmentRows(specRow, exception);
            runData(rowIndex).candidate_id = candidateId;
            runData(rowIndex).status = "EXECUTION_ERROR";
            runData(rowIndex).samples = table();
            runData(rowIndex).error_message = string(exception.message);
        end

        summaryRows(end + 1, 1) = summaryRow; %#ok<AGROW>
        segmentRows = [segmentRows; newSegmentRows]; %#ok<AGROW>
        fprintf('Status: %s', summaryRow.status);
        if strlength(summaryRow.failure_reason) > 0
            fprintf(' | %s', summaryRow.failure_reason);
        end
        fprintf('\n');
    end

    summaryTable = struct2table(summaryRows);
    segmentTable = struct2table(segmentRows);
    writetable(summaryTable, summaryFile);
    writetable(segmentTable, segmentFile);

    fprintf('\nAI MIL Suite v1 results\n');
    disp(summaryTable);
    fprintf('Summary CSV: %s\n', summaryFile);
    fprintf('Segment CSV: %s\n\n', segmentFile);
end

function parameters = localProjectParameters()
    parameters = struct();
    parameters.port_num = 7;
    parameters.ts = 0.0004;
    parameters.Vdc = 12;
    parameters.cpr = 4096;
    parameters.horizon = 20;
    parameters.pole_pair = 7;
    parameters.a = 17.76;
    parameters.b = 2185.96;
    parameters.f_cs = 40;
    parameters.w_cs = 2 * pi * parameters.f_cs;
    parameters.Kps = parameters.w_cs / parameters.b;
    parameters.Kis = parameters.a * parameters.Kps;
    parameters.Kas = parameters.Kis / parameters.Kps;
    parameters.f_cp = parameters.f_cs / 5;
    parameters.w_cp = 2 * pi * parameters.f_cp;
    parameters.Kpp = parameters.w_cp;
end

function localValidateSpecification(specification, candidateRecords, parameters)
    requiredColumns = [ ...
        "selection_order", "candidate_id", "requirement_id", ...
        "original_input_values", "segment_count", "segment_duration_s", ...
        "total_duration_s", "sample_time_s", "oracle_mapping", ...
        "applicability_check_required", "evaluation_window_s"];
    assert(all(ismember(requiredColumns, string(specification.Properties.VariableNames))), ...
        'run_ai_mil_suite:MissingSpecificationColumn', ...
        'Resolved execution specification is missing required columns.');
    assert(height(specification) == 9, ...
        'run_ai_mil_suite:UnexpectedCandidateCount', ...
        'Expected exactly 9 frozen AI candidates, found %d.', height(specification));
    assert(isequal(specification.selection_order(:), (1:9)'), ...
        'run_ai_mil_suite:InvalidSelectionOrder', ...
        'selection_order must be the ordered integers 1 through 9.');
    assert(numel(unique(specification.candidate_id)) == 9, ...
        'run_ai_mil_suite:DuplicateCandidate', ...
        'candidate_id values must be unique.');
    assert(all(specification.segment_duration_s == 2.0), ...
        'run_ai_mil_suite:UnexpectedSegmentDuration', ...
        'Every segment duration must be the frozen 2.0 s execution parameter.');
    assert(all(specification.sample_time_s == parameters.ts), ...
        'run_ai_mil_suite:UnexpectedSampleTime', ...
        'Every row must use the existing project sample time %.17g s.', parameters.ts);

    candidateIds = string({candidateRecords.candidate_id});
    for rowIndex = 1:height(specification)
        candidateId = specification.candidate_id(rowIndex);
        assert(nnz(candidateIds == candidateId) == 1, ...
            'run_ai_mil_suite:MissingCandidateMetadata', ...
            'Candidate metadata was not found exactly once for %s.', candidateId);
        values = localParseValues( ...
            specification.original_input_values(rowIndex), candidateId);
        assert(numel(values) == specification.segment_count(rowIndex), ...
            'run_ai_mil_suite:SegmentCountMismatch', ...
            'segment_count does not match input_values for %s.', candidateId);
        expectedDuration = numel(values) * specification.segment_duration_s(rowIndex);
        assert(abs(expectedDuration - specification.total_duration_s(rowIndex)) ...
            <= 64 * eps(max(1, expectedDuration)), ...
            'run_ai_mil_suite:DurationMismatch', ...
            'Resolved total duration is inconsistent for %s.', candidateId);
        assert(abs(specification.segment_duration_s(rowIndex) / parameters.ts - ...
            round(specification.segment_duration_s(rowIndex) / parameters.ts)) ...
            <= 64 * eps(1), ...
            'run_ai_mil_suite:UnalignedSegmentBoundary', ...
            'Segment duration is not aligned to ts for %s.', candidateId);
    end
end

function localValidateStoredModelConfiguration(modelName, ts)
    assert(strcmp(get_param(modelName, 'SolverType'), 'Fixed-step'), ...
        'run_ai_mil_suite:UnexpectedSolverType', ...
        'Stored SolverType must be Fixed-step.');
    assert(strcmp(get_param(modelName, 'Solver'), 'ode4'), ...
        'run_ai_mil_suite:UnexpectedSolver', ...
        'Stored Solver must be ode4.');
    assert(strcmp(get_param(modelName, 'FixedStep'), 'ts'), ...
        'run_ai_mil_suite:UnexpectedFixedStep', ...
        'Stored FixedStep must be ts.');
    assert(ts == 0.0004, ...
        'run_ai_mil_suite:UnexpectedTs', 'ts must be 0.0004 s.');
end

function stimulus = localStimulusBlocks(modelName)
    pulseBlocks = find_system(modelName, ...
        'LookUnderMasks', 'all', 'FollowLinks', 'on', ...
        'BlockType', 'DiscretePulseGenerator');
    assert(numel(pulseBlocks) == 1, ...
        'run_ai_mil_suite:UnexpectedPulseGeneratorCount', ...
        'Expected exactly one Discrete Pulse Generator block.');
    stimulus = struct( ...
        'pulse', pulseBlocks{1}, ...
        'offset', [modelName, '/Constant2'], ...
        'direct', [modelName, '/Constant3'], ...
        'switch', [modelName, '/Manual Switch'], ...
        'gain', [modelName, '/Gain1']);
    assert(strcmp(get_param(stimulus.gain, 'Gain'), '15'), ...
        'run_ai_mil_suite:UnexpectedStimulusGain', ...
        'The frozen v3 stimulus-path Gain1 must remain 15.');
end

function metadata = localCandidateMetadata(candidateRecords, candidateId)
    candidateIds = string({candidateRecords.candidate_id});
    index = find(candidateIds == candidateId, 1, 'first');
    metadata = candidateRecords(index);
end

function values = localParseValues(jsonText, candidateId)
    values = double(jsondecode(char(jsonText)));
    values = values(:)';
    assert(~isempty(values) && all(isfinite(values)), ...
        'run_ai_mil_suite:InvalidInputValues', ...
        'original_input_values must contain finite numeric values for %s.', ...
        candidateId);
end

function [signals, samples] = localSimulateCandidate( ...
        modelName, specRow, values, parameters, stimulus)
    simulationInput = Simulink.SimulationInput(modelName);
    variableNames = fieldnames(parameters);
    for variableIndex = 1:numel(variableNames)
        variableName = variableNames{variableIndex};
        simulationInput = simulationInput.setVariable( ...
            variableName, parameters.(variableName));
    end
    simulationInput = simulationInput.setVariable('SpeedRef_cmd', values(1));

    if numel(values) == 1
        simulationInput = simulationInput.setBlockParameter( ...
            stimulus.switch, 'CurrentSetting', '0');
        simulationInput = simulationInput.setBlockParameter( ...
            stimulus.direct, 'Value', 'SpeedRef_cmd');
    else
        firstValue = values(1);
        secondValue = values(2);
        expectedValues = repmat([firstValue, secondValue], 1, ceil(numel(values) / 2));
        expectedValues = expectedValues(1:numel(values));
        numericTolerance = 64 * eps(max([1, abs(values)]));
        assert(all(abs(values - expectedValues) <= numericTolerance), ...
            'run_ai_mil_suite:UnsupportedSequenceShape', ...
            ['The frozen model stimulus path supports the selected equal-duration ', ...
             'two-level alternating sequence; candidate %s does not match it.'], ...
            specRow.candidate_id);

        stimulusGain = 15;
        pulseAmplitude = (firstValue - secondValue) / stimulusGain;
        offsetValue = -secondValue / stimulusGain;
        pulsePeriod_s = 2 * specRow.segment_duration_s;

        simulationInput = simulationInput.setBlockParameter( ...
            stimulus.pulse, 'Amplitude', sprintf('%.17g', pulseAmplitude));
        simulationInput = simulationInput.setBlockParameter( ...
            stimulus.pulse, 'Period', sprintf('%.17g', pulsePeriod_s));
        simulationInput = simulationInput.setBlockParameter( ...
            stimulus.pulse, 'PulseWidth', '50');
        simulationInput = simulationInput.setBlockParameter( ...
            stimulus.pulse, 'PhaseDelay', '0');
        simulationInput = simulationInput.setBlockParameter( ...
            stimulus.pulse, 'SampleTime', 'ts');
        simulationInput = simulationInput.setBlockParameter( ...
            stimulus.offset, 'Value', sprintf('%.17g', offsetValue));
        simulationInput = simulationInput.setBlockParameter( ...
            stimulus.switch, 'CurrentSetting', '1');
    end

    simulationInput = simulationInput.setModelParameter( ...
        'StopTime', sprintf('%.17g', specRow.total_duration_s), ...
        'SignalLogging', 'on', ...
        'SignalLoggingName', 'logsout', ...
        'SignalLoggingSaveFormat', 'Dataset', ...
        'ReturnWorkspaceOutputs', 'on');

    simulationOutput = sim(simulationInput);
    logsout = simulationOutput.get('logsout');
    assert(isa(logsout, 'Simulink.SimulationData.Dataset'), ...
        'run_ai_mil_suite:MissingLogsout', ...
        'Expected logsout Dataset was not produced.');

    referenceSignal = localGetLoggedSignal(logsout, 'reference');
    motorSpeedSignal = localGetLoggedSignal(logsout, 'motorspeed');
    vcmdSignal = localGetLoggedSignal(logsout, 'Vcmd');
    rawPiSignal = localGetLoggedSignal(logsout, 'raw_pi_output');

    time = double(motorSpeedSignal.Time(:));
    motorspeed = double(squeeze(motorSpeedSignal.Data));
    motorspeed = motorspeed(:);
    reference = localAlignSignal(referenceSignal, time);
    vcmd = localAlignSignal(vcmdSignal, time);
    rawPiOutput = localAlignSignal(rawPiSignal, time);

    % The periodic stimulus source returns to its first value exactly at a
    % whole-period StopTime. That sample is the start of the next, unrequested
    % segment, not part of the frozen half-open sequence [0, totalDuration).
    % Remove only this terminal source-wrap sample for sequence candidates.
    if numel(values) > 1
        requestedRows = time < specRow.total_duration_s;
        time = time(requestedRows);
        reference = reference(requestedRows);
        motorspeed = motorspeed(requestedRows);
        vcmd = vcmd(requestedRows);
        rawPiOutput = rawPiOutput(requestedRows);
    end

    assert(all(isfinite(time)) && all(isfinite(reference)) && ...
        all(isfinite(motorspeed)) && all(isfinite(vcmd)) && ...
        all(isfinite(rawPiOutput)), ...
        'run_ai_mil_suite:NonfiniteSignal', ...
        'Logged signals contain NaN or Inf.');
    assert(all(diff(time) > 0), ...
        'run_ai_mil_suite:InvalidLoggedTime', ...
        'Logged time must be strictly increasing.');

    localVerifyLoggedWaveform( ...
        time, reference, values, specRow.segment_duration_s, ...
        specRow.total_duration_s);

    signals = struct( ...
        'time', time, ...
        'reference', reference, ...
        'motorspeed', motorspeed, ...
        'vcmd', vcmd, ...
        'raw_pi_output', rawPiOutput);
    samples = table(time, reference, motorspeed, vcmd, rawPiOutput, ...
        'VariableNames', { ...
        'time_s', 'reference_rps', 'motorspeed_rps', ...
        'Vcmd_v', 'raw_pi_output_v'});
end

function localVerifyLoggedWaveform( ...
        time, reference, values, segmentDuration_s, totalDuration_s)
    for segmentIndex = 1:numel(values)
        startTime_s = (segmentIndex - 1) * segmentDuration_s;
        endTime_s = segmentIndex * segmentDuration_s;
        if segmentIndex < numel(values)
            rows = time >= startTime_s & time < endTime_s;
        else
            rows = time >= startTime_s & time <= totalDuration_s;
        end
        assert(any(rows), ...
            'run_ai_mil_suite:EmptyWaveformSegment', ...
            'No logged samples were found for segment %d.', segmentIndex);
        tolerance = 64 * eps(max(1, abs(values(segmentIndex))));
        assert(all(abs(reference(rows) - values(segmentIndex)) <= tolerance), ...
            'run_ai_mil_suite:WaveformMismatch', ...
            'Logged reference does not match segment %d.', segmentIndex);
    end
end

function [summaryRow, detailRows] = localEvaluateCandidate( ...
        specRow, metadata, values, signals, parameters)
    numberOfSegments = numel(values);
    detailRows = repmat(localEmptySegmentRow(), numberOfSegments, 1);
    requiredResults = strings(0, 1);
    applicabilityResults = strings(0, 1);

    fullVoltageResult = struct();
    if specRow.requirement_id == "REQ-VOLT-001"
        fullVoltageResult = evaluate_voltage_limit( ...
            signals.time, signals.vcmd, parameters.Vdc);
        requiredResults(end + 1, 1) = localPassFail(fullVoltageResult.pass);
    end

    previousNonzeroSign = 0;
    for segmentIndex = 1:numberOfSegments
        startTime_s = (segmentIndex - 1) * specRow.segment_duration_s;
        endTime_s = segmentIndex * specRow.segment_duration_s;
        if segmentIndex < numberOfSegments
            rows = signals.time >= startTime_s & signals.time < endTime_s;
        else
            rows = signals.time >= startTime_s & ...
                signals.time <= specRow.total_duration_s;
        end
        assert(any(rows), ...
            'run_ai_mil_suite:EmptyEvaluationSegment', ...
            'No samples were found for evaluation segment %d.', segmentIndex);

        segmentTime = signals.time(rows);
        segmentReference = signals.reference(rows);
        segmentMotorSpeed = signals.motorspeed(rows);
        segmentVcmd = signals.vcmd(rows);
        segmentRawPi = signals.raw_pi_output(rows);

        detail = localEmptySegmentRow();
        detail.candidate_id = specRow.candidate_id;
        detail.segment_index = segmentIndex;
        detail.reference_rps = values(segmentIndex);
        detail.start_time_s = startTime_s;
        detail.end_time_s = endTime_s;
        detail.applicability = "NOT_REQUIRED";
        detail.direction_result = "NOT_EVALUATED";
        detail.tracking_result = "NOT_EVALUATED";
        detail.voltage_result = "NOT_EVALUATED";
        detail.notes = "";

        if specRow.requirement_id == "REQ-DIR-001" && ...
                segmentIndex == numberOfSegments
            directionResult = evaluate_direction( ...
                segmentTime, segmentReference, segmentMotorSpeed);
            detail.evaluation_start_s = directionResult.evaluation_start_time_s;
            detail.evaluation_end_s = segmentTime(end);
            detail.direction_result = localPassFail(directionResult.pass);
            requiredResults(end + 1, 1) = detail.direction_result; %#ok<AGROW>

        elseif specRow.requirement_id == "REQ-TRK-001"
            [persistentClamp, gateNote] = localPersistentTerminalClamp( ...
                segmentTime, segmentRawPi, segmentVcmd, parameters.Vdc, ...
                specRow.evaluation_window_s);
            detail.evaluation_start_s = segmentTime(end) - specRow.evaluation_window_s;
            detail.evaluation_end_s = segmentTime(end);
            if persistentClamp
                detail.applicability = "PRECONDITION_NOT_MET";
                detail.tracking_result = "INCONCLUSIVE_PRECONDITION";
                detail.notes = gateNote;
                applicabilityResults(end + 1, 1) = ...
                    "PRECONDITION_NOT_MET"; %#ok<AGROW>
            else
                trackingResult = evaluate_tracking( ...
                    segmentTime, segmentReference, segmentMotorSpeed);
                detail.applicability = "APPLICABLE";
                detail.evaluation_start_s = ...
                    trackingResult.evaluation_start_time_s;
                detail.tracking_result = localPassFail(trackingResult.pass);
                requiredResults(end + 1, 1) = detail.tracking_result; %#ok<AGROW>
                applicabilityResults(end + 1, 1) = "APPLICABLE"; %#ok<AGROW>
            end

        elseif specRow.requirement_id == "REQ-REV-001"
            currentSign = sign(values(segmentIndex));
            isPostReversal = previousNonzeroSign ~= 0 && ...
                currentSign ~= 0 && currentSign ~= previousNonzeroSign;
            if isPostReversal
                directionResult = evaluate_direction( ...
                    segmentTime, segmentReference, segmentMotorSpeed);
                trackingResult = evaluate_tracking( ...
                    segmentTime, segmentReference, segmentMotorSpeed);
                detail.evaluation_start_s = max( ...
                    directionResult.evaluation_start_time_s, ...
                    trackingResult.evaluation_start_time_s);
                detail.evaluation_end_s = segmentTime(end);
                detail.direction_result = localPassFail(directionResult.pass);
                detail.tracking_result = localPassFail(trackingResult.pass);
                if directionResult.pass && trackingResult.pass
                    requiredResults(end + 1, 1) = "PASS"; %#ok<AGROW>
                else
                    requiredResults(end + 1, 1) = "FAIL"; %#ok<AGROW>
                end
                detail.notes = "Post-reversal plateau evaluated.";
            else
                detail.notes = "Initial or non-reversal plateau; no REQ-REV Oracle evaluation.";
            end
            if currentSign ~= 0
                previousNonzeroSign = currentSign;
            end

        elseif specRow.requirement_id == "REQ-VOLT-001"
            segmentVoltageResult = evaluate_voltage_limit( ...
                segmentTime, segmentVcmd, parameters.Vdc);
            detail.evaluation_start_s = segmentTime(1);
            detail.evaluation_end_s = segmentTime(end);
            detail.voltage_result = localPassFail(segmentVoltageResult.pass);
            detail.notes = ...
                "Segment evidence; top-level Voltage Oracle uses the complete simulation interval.";
        end

        detailRows(segmentIndex) = detail;
    end

    assert(~isempty(requiredResults), ...
        'run_ai_mil_suite:NoRequiredEvaluation', ...
        'No required Oracle evaluation was produced for %s.', specRow.candidate_id);

    if any(requiredResults == "FAIL")
        status = "FAIL";
        failureReason = "At least one required Oracle evaluation failed.";
    elseif any(applicabilityResults == "PRECONDITION_NOT_MET")
        status = "INCONCLUSIVE_PRECONDITION";
        failureReason = ...
            "Persistent terminal saturation made at least one tracking plateau inapplicable.";
    else
        status = "PASS";
        failureReason = "";
    end

    if specRow.requirement_id == "REQ-TRK-001"
        if all(applicabilityResults == "APPLICABLE")
            applicability = "APPLICABLE";
        elseif all(applicabilityResults == "PRECONDITION_NOT_MET")
            applicability = "PRECONDITION_NOT_MET";
        else
            applicability = "PARTIALLY_APPLICABLE";
        end
    else
        applicability = "NOT_REQUIRED";
    end

    summaryRow = localEmptySummaryRow();
    summaryRow.selection_order = specRow.selection_order;
    summaryRow.candidate_id = specRow.candidate_id;
    summaryRow.requirement_id = specRow.requirement_id;
    summaryRow.test_scope = string(metadata.test_scope);
    summaryRow.test_design_technique = string(metadata.test_design_technique);
    summaryRow.total_duration_s = specRow.total_duration_s;
    summaryRow.status = status;
    summaryRow.oracle = specRow.oracle_mapping;
    summaryRow.applicability = applicability;
    summaryRow.failure_reason = failureReason;

    if specRow.requirement_id == "REQ-VOLT-001" && ~fullVoltageResult.pass
        summaryRow.failure_reason = sprintf( ...
            'Complete-interval Vcmd range [%+.17g, %+.17g] V exceeded limits.', ...
            fullVoltageResult.min_vcmd_v, fullVoltageResult.max_vcmd_v);
    end
end

function [persistentClamp, note] = localPersistentTerminalClamp( ...
        time, rawPiOutput, vcmd, voltageLimit, evaluationWindow_s)
    evaluationStart_s = time(end) - evaluationWindow_s;
    rows = time >= evaluationStart_s;
    assert(any(rows), ...
        'run_ai_mil_suite:EmptyApplicabilityWindow', ...
        'No samples were found in the Tracking applicability window.');

    terminalRawPi = rawPiOutput(rows);
    terminalVcmd = vcmd(rows);
    numericTolerance_v = 64 * eps(max([1; abs(terminalVcmd); voltageLimit]));
    positiveClamp = terminalRawPi > voltageLimit & ...
        abs(terminalVcmd - voltageLimit) <= numericTolerance_v;
    negativeClamp = terminalRawPi < -voltageLimit & ...
        abs(terminalVcmd + voltageLimit) <= numericTolerance_v;
    persistentClamp = all(positiveClamp | negativeClamp);

    if persistentClamp
        note = sprintf([ ...
            'Persistent terminal clamp over the complete %.17g s window; ', ...
            'numeric clamp comparison uses %.3g V machine-scale tolerance.'], ...
            evaluationWindow_s, numericTolerance_v);
    else
        note = "Tracking applicability condition met.";
    end
end

function signal = localGetLoggedSignal(logsout, signalName)
    element = logsout.get(signalName);
    if isempty(element)
        error('run_ai_mil_suite:MissingSignal', ...
            'Logged signal "%s" was not found.', signalName);
    end
    signal = element.Values;
end

function values = localAlignSignal(signal, targetTime)
    signalTime = double(signal.Time(:));
    signalData = double(squeeze(signal.Data));
    signalData = signalData(:);
    if isequal(signalTime, targetTime)
        values = signalData;
    else
        values = interp1(signalTime, signalData, targetTime, ...
            'previous', 'extrap');
    end
end

function row = localEmptySummaryRow()
    row = struct( ...
        'selection_order', NaN, ...
        'candidate_id', "", ...
        'requirement_id', "", ...
        'test_scope', "", ...
        'test_design_technique', "", ...
        'total_duration_s', NaN, ...
        'status', "", ...
        'oracle', "", ...
        'applicability', "", ...
        'failure_reason', "");
end

function row = localEmptySegmentRow()
    row = struct( ...
        'candidate_id', "", ...
        'segment_index', NaN, ...
        'reference_rps', NaN, ...
        'start_time_s', NaN, ...
        'end_time_s', NaN, ...
        'evaluation_start_s', NaN, ...
        'evaluation_end_s', NaN, ...
        'applicability', "", ...
        'direction_result', "", ...
        'tracking_result', "", ...
        'voltage_result', "", ...
        'notes', "");
end

function row = localErrorSummaryRow(specRow, metadata, exception)
    row = localEmptySummaryRow();
    row.selection_order = specRow.selection_order;
    row.candidate_id = specRow.candidate_id;
    row.requirement_id = specRow.requirement_id;
    row.test_scope = string(metadata.test_scope);
    row.test_design_technique = string(metadata.test_design_technique);
    row.total_duration_s = specRow.total_duration_s;
    row.status = "EXECUTION_ERROR";
    row.oracle = specRow.oracle_mapping;
    row.applicability = "NOT_EVALUATED";
    row.failure_reason = string(exception.message);
end

function rows = localErrorSegmentRows(specRow, exception)
    rows = repmat(localEmptySegmentRow(), specRow.segment_count, 1);
    values = localParseValues(specRow.original_input_values, specRow.candidate_id);
    for segmentIndex = 1:specRow.segment_count
        rows(segmentIndex).candidate_id = specRow.candidate_id;
        rows(segmentIndex).segment_index = segmentIndex;
        rows(segmentIndex).reference_rps = values(segmentIndex);
        rows(segmentIndex).start_time_s = ...
            (segmentIndex - 1) * specRow.segment_duration_s;
        rows(segmentIndex).end_time_s = segmentIndex * specRow.segment_duration_s;
        rows(segmentIndex).applicability = "NOT_EVALUATED";
        rows(segmentIndex).direction_result = "EXECUTION_ERROR";
        rows(segmentIndex).tracking_result = "EXECUTION_ERROR";
        rows(segmentIndex).voltage_result = "EXECUTION_ERROR";
        rows(segmentIndex).notes = string(exception.message);
    end
end

function result = localPassFail(pass)
    if pass
        result = "PASS";
    else
        result = "FAIL";
    end
end

function localAssertFile(path, description)
    assert(isfile(path), 'run_ai_mil_suite:MissingDependency', ...
        '%s was not found: %s', description, path);
end

function localCloseModel(modelName, modelWasLoaded)
    if ~modelWasLoaded && bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end
