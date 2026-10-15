function demo = run_interview_demo()
%RUN_INTERVIEW_DEMO Run a read-only presentation subset of frozen MIL tests.
%   This is a presentation-only demonstration of the existing verification
%   infrastructure. It does not create verification evidence or write result
%   artifacts. Official evidence remains the frozen scalability execution.

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    resultDirectory = fullfile( ...
        repositoryRoot, 'results', 'scalability_extension_v1');

    % These candidates are a post-hoc presentation subset selected from the
    % frozen per_mutant_first_kill.csv. This is not an independent Test Suite
    % selection and is not a new verification experiment.
    selectedCandidateIDs = [
        "EXT-B04-TC-008"
        "EXT-B01-CAND-025"
    ];
    mutationIDs = "MUT-" + compose('%03d', (1:6)');
    runID = "INTERVIEW_DEMO_" + string(datetime('now', ...
        'Format', 'yyyyMMdd_HHmmss_SSS'));

    protectedFiles = [
        string(fullfile(repositoryRoot, 'model', ...
            'AS2308_MIL_Baseline_v3.slx'))
        string(fullfile(resultDirectory, 'healthy_execution_results.csv'))
        string(fullfile(resultDirectory, 'mutation_execution_results.csv'))
        string(fullfile(resultDirectory, 'mutation_kill_matrix.csv'))
        string(fullfile(resultDirectory, 'runtime_summary.csv'))
    ];
    integrityBefore = localCaptureIntegrity(protectedFiles);
    demoTimer = tic;

    demo = struct( ...
        'run_id', runID, ...
        'selected_candidate_ids', selectedCandidateIDs, ...
        'healthy_results', table(), ...
        'mutant_results', table(), ...
        'kill_matrix', table(), ...
        'mutant_summary', table(), ...
        'total_execution_count', 0, ...
        'elapsed_time_s', NaN);

    fprintf('\n============================================================\n');
    fprintf('AS2308 SW Verification - Interview Demo\n');
    fprintf('Presentation subset - NOT official verification evidence\n');
    fprintf('============================================================\n');

    try
        fprintf('\n[1/4] Infrastructure Preflight\n');
        preflight = run_scalability_extension('Execute', false);
        assert(~preflight.execute && ...
            preflight.completion_status == "PREFLIGHT_ONLY", ...
            'run_interview_demo:UnexpectedPreflightResult', ...
            'Scalability preflight did not return the expected state.');
        fprintf('Preflight: PASS\n');

        fprintf('\n[2/4] Healthy MIL\n');
        [healthyResults, healthySegments] = run_ai_scalability_suite( ...
            'Execute', true, ...
            'MutationID', "BASELINE", ...
            'WriteResults', false, ...
            'CandidateIDs', selectedCandidateIDs, ...
            'RunID', runID);
        localAssertExecutionIdentity(healthyResults, selectedCandidateIDs, ...
            "healthy");
        demo.healthy_results = healthyResults;

        healthyDisplay = table( ...
            healthyResults.extension_candidate_id, ...
            healthyResults.requirement_id, ...
            healthyResults.status, ...
            healthyResults.elapsed_time_s, ...
            'VariableNames', {'TestCase', 'Requirement', ...
            'HealthyStatus', 'ElapsedTime_s'});
        disp(healthyDisplay);

        healthyPassCount = sum(healthyResults.status == "PASS");
        if healthyPassCount ~= numel(selectedCandidateIDs)
            fprintf('Healthy Gate: FAIL (%d/%d PASS)\n', ...
                healthyPassCount, numel(selectedCandidateIDs));
            fprintf(['Fail-safe gate active: mutation execution was not ', ...
                'started.\n']);
            error('run_interview_demo:HealthyGateFailed', ...
                ['Mutation demo requires every selected healthy execution ', ...
                'to PASS.']);
        end
        fprintf('Healthy Gate: PASS (%d/%d)\n', ...
            healthyPassCount, numel(selectedCandidateIDs));

        fprintf('\n[3/4] Mutation Detection\n');
        mutantResults = table();
        killValues = false(numel(selectedCandidateIDs), numel(mutationIDs));
        mutantStatusValues = strings( ...
            numel(selectedCandidateIDs), numel(mutationIDs));

        for mutationIndex = 1:numel(mutationIDs)
            mutationID = mutationIDs(mutationIndex);
            [mutantExecution, ~] = run_ai_scalability_suite( ...
                'Execute', true, ...
                'MutationID', mutationID, ...
                'WriteResults', false, ...
                'BaselineSegmentResults', healthySegments, ...
                'CandidateIDs', selectedCandidateIDs, ...
                'RunID', runID);
            localAssertExecutionIdentity(mutantExecution, ...
                selectedCandidateIDs, mutationID);

            % Frozen KILL semantics: only Healthy PASS && Mutant FAIL kills.
            % All other statuses, including execution errors and
            % inconclusive preconditions, are explicitly non-kills.
            kills = healthyResults.status == "PASS" & ...
                mutantExecution.status == "FAIL";
            killValues(:, mutationIndex) = kills;
            mutantStatusValues(:, mutationIndex) = mutantExecution.status;

            rows = table( ...
                repmat(runID, height(mutantExecution), 1), ...
                repmat(mutationID, height(mutantExecution), 1), ...
                mutantExecution.extension_candidate_id, ...
                mutantExecution.requirement_id, ...
                healthyResults.status, ...
                mutantExecution.status, ...
                kills, ...
                mutantExecution.elapsed_time_s, ...
                mutantExecution.failure_reason, ...
                'VariableNames', {'run_id', 'mutation_id', ...
                'extension_candidate_id', 'requirement_id', ...
                'healthy_status', 'mutant_status', 'kill', ...
                'elapsed_time_s', 'failure_reason'});
            mutantResults = [mutantResults; rows]; %#ok<AGROW>
        end
        demo.mutant_results = mutantResults;

        killLabels = mutantStatusValues;
        killLabels(killLabels == "INCONCLUSIVE_PRECONDITION") = ...
            "INCONCLUSIVE";
        killLabels(killValues) = "KILL";
        killMatrix = table(selectedCandidateIDs, healthyResults.status, ...
            'VariableNames', {'TestCase', 'Healthy'});
        for mutationIndex = 1:numel(mutationIDs)
            variableName = matlab.lang.makeValidName(mutationIDs(mutationIndex));
            killMatrix.(variableName) = killLabels(:, mutationIndex);
        end
        demo.kill_matrix = killMatrix;
        localDisplayKillMatrix(selectedCandidateIDs, healthyResults.status, ...
            mutationIDs, killLabels);

        killingTestCount = sum(killValues, 1)';
        mutantSummary = table(mutationIDs, killingTestCount > 0, ...
            killingTestCount, 'VariableNames', ...
            {'Mutant', 'KilledInDemo', 'KillingTestCount'});
        demo.mutant_summary = mutantSummary;
        disp(mutantSummary);
        fprintf('Mutants detected: %d/%d\n', ...
            sum(mutantSummary.KilledInDemo), height(mutantSummary));

        healthyExecutionCount = height(healthyResults);
        mutationExecutionCount = height(mutantResults);
        totalExecutionCount = healthyExecutionCount + mutationExecutionCount;
        executionErrorCount = sum(healthyResults.status == ...
            "EXECUTION_ERROR") + sum(mutantResults.mutant_status == ...
            "EXECUTION_ERROR");
        elapsedTime = toc(demoTimer);
        demo.total_execution_count = totalExecutionCount;
        demo.elapsed_time_s = elapsedTime;

        localAssertIntegrity(integrityBefore, protectedFiles);

        fprintf('\n[4/4] Demo Summary\n');
        fprintf('Healthy executions : %d\n', healthyExecutionCount);
        fprintf('Healthy PASS count : %d\n', healthyPassCount);
        fprintf('Mutation executions: %d\n', mutationExecutionCount);
        fprintf('Total simulations  : %d\n', totalExecutionCount);
        fprintf('Mutants killed     : %d/%d\n', ...
            sum(mutantSummary.KilledInDemo), height(mutantSummary));
        fprintf('Execution errors   : %d\n', executionErrorCount);
        fprintf('Automatic retries  : 0\n');
        fprintf('Result writes      : 0\n');
        fprintf('AI API calls       : 0\n');
        fprintf('Elapsed wall time  : %.3f s\n', elapsedTime);
        fprintf('Integrity check    : PASS (authoritative files unchanged)\n');

        localDisplayOfficialEvidence(resultDirectory);
        fprintf(['\nPresentation-only subset demo.\n', ...
            'Official verification evidence remains the frozen ', ...
            '700-simulation scalability run.\n']);
    catch exception
        localAssertIntegrity(integrityBefore, protectedFiles);
        rethrow(exception);
    end
end

function localDisplayKillMatrix(candidateIDs, healthyStatus, mutationIDs, labels)
    fprintf('\n%-22s %-10s', 'TestCase', 'Healthy');
    for mutationIndex = 1:numel(mutationIDs)
        fprintf(' %-13s', mutationIDs(mutationIndex));
    end
    fprintf('\n%s\n', repmat('-', 1, 22 + 11 + 14 * numel(mutationIDs)));
    for candidateIndex = 1:numel(candidateIDs)
        fprintf('%-22s %-10s', ...
            candidateIDs(candidateIndex), healthyStatus(candidateIndex));
        for mutationIndex = 1:numel(mutationIDs)
            fprintf(' %-13s', labels(candidateIndex, mutationIndex));
        end
        fprintf('\n');
    end
    fprintf('\n');
end

function localAssertExecutionIdentity(results, expectedIDs, executionLabel)
    assert(height(results) == numel(expectedIDs), ...
        'run_interview_demo:UnexpectedExecutionCount', ...
        '%s execution returned %d rows; expected %d.', ...
        executionLabel, height(results), numel(expectedIDs));
    actualIDs = string(results.extension_candidate_id);
    assert(isequal(actualIDs, expectedIDs), ...
        'run_interview_demo:UnexpectedExecutionIdentity', ...
        '%s execution identity/order differs from the presentation subset.', ...
        executionLabel);
end

function snapshot = localCaptureIntegrity(paths)
    snapshot = table(paths, isfile(paths), strings(numel(paths), 1), ...
        'VariableNames', {'path', 'exists', 'sha256'});
    for index = 1:height(snapshot)
        if snapshot.exists(index)
            snapshot.sha256(index) = localFileSha256(snapshot.path(index));
        end
    end
end

function localAssertIntegrity(before, paths)
    after = localCaptureIntegrity(paths);
    unchanged = before.exists == after.exists & ...
        before.sha256 == after.sha256;
    assert(all(unchanged), 'run_interview_demo:AuthoritativeArtifactChanged', ...
        'Demo changed an authoritative file: %s', ...
        strjoin(before.path(~unchanged), ', '));
end

function hash = localFileSha256(path)
    fid = fopen(path, 'rb');
    assert(fid >= 0, 'run_interview_demo:HashReadFailed', ...
        'Cannot read file for SHA-256: %s', path);
    cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    bytes = fread(fid, Inf, '*uint8');
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(typecast(bytes, 'int8'));
    hash = upper(string(reshape( ...
        dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, [])));
end

function localDisplayOfficialEvidence(resultDirectory)
    runtimeFile = fullfile(resultDirectory, 'runtime_summary.csv');
    healthyFile = fullfile(resultDirectory, 'healthy_execution_results.csv');
    fprintf('\nOfficial frozen scalability evidence (read-only CSV):\n');
    if ~isfile(runtimeFile)
        fprintf('UNAVAILABLE: %s\n', runtimeFile);
        return;
    end

    try
        runtime = readtable(runtimeFile, 'TextType', 'string');
        required = ["healthy_execution_count", ...
            "mutation_execution_count", "total_execution_count", ...
            "total_simulation_elapsed_time_s", "execution_error_count", ...
            "automatic_retry_count"];
        assert(height(runtime) >= 1 && all(ismember(required, ...
            string(runtime.Properties.VariableNames))), ...
            'run_interview_demo:InvalidOfficialRuntimeSummary', ...
            'Official runtime summary is missing required data.');
        row = runtime(end, :);

        if isfile(healthyFile)
            healthy = readtable(healthyFile, 'TextType', 'string');
            healthyPassCount = sum(healthy.status == "PASS");
            fprintf('Healthy              : %d/%d PASS\n', ...
                healthyPassCount, row.healthy_execution_count);
        else
            fprintf('Healthy              : UNAVAILABLE\n');
        end
        fprintf('Mutation executions  : %d\n', ...
            row.mutation_execution_count);
        fprintf('Total simulations    : %d\n', row.total_execution_count);
        fprintf('Execution errors     : %d\n', row.execution_error_count);
        fprintf('Automatic retries    : %d\n', row.automatic_retry_count);
        fprintf('Simulation elapsed   : approximately %.1f s\n', ...
            row.total_simulation_elapsed_time_s);
    catch exception
        fprintf('UNAVAILABLE: %s\n', exception.message);
    end
end
