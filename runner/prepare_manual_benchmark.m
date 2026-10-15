function session = prepare_manual_benchmark()
%PREPARE_MANUAL_BENCHMARK Prepare a manual, non-executing MIL workspace.
%   This function creates and opens a temporary copy of the frozen source
%   model with the validated From Workspace stimulus path. It does not run a
%   simulation, evaluate an Oracle, record a result, or advance Test Cases.

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    sourceModel = fullfile( ...
        repositoryRoot, 'model', 'AS2308_MIL_Baseline_v3.slx');
    specificationFile = fullfile(repositoryRoot, 'results', ...
        'scalability_extension_v1', ...
        'candidate_execution_spec_resolved.csv');
    protocolFile = fullfile(repositoryRoot, 'docs', ...
        '10_Manual_vs_Automation_Benchmark_Protocol.md');
    benchmarkSheetFile = fullfile(repositoryRoot, 'benchmark', ...
        'manual_benchmark_sheet.csv');

    localAssertFile(sourceModel, 'Frozen source model');
    localAssertFile(specificationFile, 'Frozen execution specification');
    localAssertFile(protocolFile, 'Manual benchmark protocol');
    localAssertFile(benchmarkSheetFile, 'Manual benchmark sheet');

    expectedCandidateIDs = [
        "EXT-B01-CAND-023"
        "EXT-B04-TC-008"
        "EXT-B01-CAND-011"
        "EXT-B05-TC-016"
        "EXT-B01-CAND-025"
        "EXT-B02-TC-015"
        "EXT-B07-TC-002"
        "EXT-B04-TC-020"
        "EXT-B04-TC-001"
        "EXT-B01-CAND-007"
        "EXT-B04-TC-017"
        "EXT-B07-TC-025"
        "EXT-B07-TC-017"
        "EXT-B01-CAND-003"
        "EXT-B04-TC-019"
        "EXT-B05-TC-019"
        "EXT-B06-TC-007"
        "EXT-B01-CAND-001"
        "EXT-B06-TC-017"
        "EXT-B06-TC-024"
        "EXT-B06-TC-003"
        "EXT-B02-TC-014"
        "EXT-B01-CAND-010"
        "EXT-B04-TC-021"
        "EXT-B01-CAND-024"
    ];
    specification = localReadSpecification(specificationFile);
    firstTwentyFive = specification(specification.selection_order >= 1 & ...
        specification.selection_order <= 25, :);
    firstTwentyFive = sortrows(firstTwentyFive, 'selection_order');
    assert(height(firstTwentyFive) == 25 && ...
        isequal(firstTwentyFive.selection_order, (1:25)') && ...
        isequal(firstTwentyFive.extension_candidate_id, ...
        expectedCandidateIDs), ...
        'prepare_manual_benchmark:FrozenOrderingMismatch', ...
        'Frozen selection_order 1-25 does not match the benchmark protocol.');
    assert(all(firstTwentyFive.segment_duration_s == 2.0), ...
        'prepare_manual_benchmark:SegmentDurationMismatch', ...
        'Every manual benchmark segment must use 2.0 s.');

    sourceHashBefore = localFileSha256(sourceModel);
    parameters = localProjectParameters();
    harness = scalability_stimulus_harness( ...
        'create', sourceModel, parameters.ts);
    cleanupRequired = true;
    try
        modelName = char(harness.model_name);
        sourceBlock = char(harness.source_block);

        % Change only the unsaved temporary harness variable name. The
        % validated source topology, controller, plant, and logging points
        % remain unchanged. The user must type each profile manually.
        set_param(sourceBlock, ...
            'VariableName', 'manual_speedref', ...
            'Interpolate', 'off', ...
            'OutputAfterFinalValue', 'Holding final value');
        set_param(modelName, ...
            'SignalLogging', 'on', ...
            'SignalLoggingName', 'logsout', ...
            'SignalLoggingSaveFormat', 'Dataset', ...
            'ReturnWorkspaceOutputs', 'off');

        parameterNames = fieldnames(parameters);
        for index = 1:numel(parameterNames)
            assignin('base', parameterNames{index}, ...
                parameters.(parameterNames{index}));
        end

        sourceHashAfter = localFileSha256(sourceModel);
        assert(sourceHashAfter == sourceHashBefore && ...
            sourceHashAfter == harness.source_sha256, ...
            'prepare_manual_benchmark:SourceHashChanged', ...
            'Frozen source model changed while preparing the manual harness.');

        open_system(modelName);
        cleanupRequired = false;
    catch exception
        if cleanupRequired
            scalability_stimulus_harness('cleanup', harness);
        end
        rethrow(exception);
    end

    session = struct( ...
        'repository_root', string(repositoryRoot), ...
        'source_model_file', string(sourceModel), ...
        'source_model_sha256', sourceHashBefore, ...
        'harness', harness, ...
        'model_name', harness.model_name, ...
        'model_file', harness.model_file, ...
        'workspace_variable', "manual_speedref", ...
        'logged_signals', ["reference"; "motorspeed"; "Vcmd"; ...
        "raw_pi_output"], ...
        'protocol_file', string(protocolFile), ...
        'benchmark_sheet_file', string(benchmarkSheetFile), ...
        'specification_file', string(specificationFile), ...
        'benchmark_case_count', height(firstTwentyFive), ...
        'first_twenty_five_specification', firstTwentyFive, ...
        'simulation_executed', false, ...
        'oracle_evaluated', false);

    first = firstTwentyFive(1, :);
    fprintf('\n============================================================\n');
    fprintf('AS2308 Manual Benchmark Environment\n');
    fprintf('Setup only - no simulation or Oracle evaluation performed\n');
    fprintf('============================================================\n');
    fprintf('Temporary model : %s\n', session.model_name);
    fprintf('Source SHA-256  : %s\n', session.source_model_sha256);
    fprintf('Input variable  : manual_speedref (two-column [time, rps])\n');
    fprintf('Interpolation   : off (piecewise constant)\n');
    fprintf(['Logged signals  : reference, motorspeed, Vcmd, ', ...
        'raw_pi_output\n']);
    fprintf('Benchmark cases : %d (frozen prefix 25)\n', ...
        session.benchmark_case_count);
    fprintf('Protocol        : %s\n', session.protocol_file);
    fprintf('Benchmark sheet : %s\n', session.benchmark_sheet_file);
    fprintf(['Evaluation      : same Healthy semantics as ', ...
        'run_ai_scalability_suite.m\n']);
    fprintf(['Before TRK/REV judgment, check evaluation_intervals_s ', ...
        'and the applicable precondition.\n']);
    fprintf('\nFirst Test Case (enter manually after starting stopwatch)\n');
    fprintf('Order           : %d\n', first.selection_order);
    fprintf('Test Case       : %s\n', first.extension_candidate_id);
    fprintf('Requirement     : %s\n', first.requirement_id);
    fprintf('SpeedRef values : %s rps\n', first.original_input_values);
    fprintf('Segment duration: %.1f s\n', first.segment_duration_s);
    fprintf('Stop Time       : %.1f s\n', first.total_duration_s);
    fprintf(['\nCleanup after the benchmark:\n', ...
        'scalability_stimulus_harness(''cleanup'', session.harness);\n']);
    fprintf(['\nNo Test Case was loaded into manual_speedref, no simulation ', ...
        'was run, and no result was calculated.\n']);
end

function specification = localReadSpecification(path)
    options = detectImportOptions(path, 'TextType', 'string');
    options = setvartype(options, options.VariableNames, 'string');
    specification = readtable(path, options);
    numericNames = {'selection_order', 'segment_duration_s', ...
        'total_duration_s'};
    for index = 1:numel(numericNames)
        name = numericNames{index};
        specification.(name) = str2double(specification.(name));
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

function localAssertFile(path, description)
    assert(isfile(path), 'prepare_manual_benchmark:MissingDependency', ...
        '%s was not found: %s', description, path);
end

function hash = localFileSha256(path)
    fid = fopen(path, 'rb');
    assert(fid >= 0, 'prepare_manual_benchmark:HashReadFailed', ...
        'Cannot read file for SHA-256: %s', path);
    cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    bytes = fread(fid, Inf, '*uint8');
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(typecast(bytes, 'int8'));
    hash = upper(string(reshape( ...
        dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, [])));
end
