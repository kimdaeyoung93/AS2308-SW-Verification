function [executionTable, killMatrix, summary] = run_ai_scalability_mutation_analysis(varargin)
%RUN_AI_SCALABILITY_MUTATION_ANALYSIS Run the frozen six-mutant analysis.
%   With Execute=false this function performs read-only preflight only.

    p = inputParser;
    addParameter(p, 'Execute', true, @(x)islogical(x) && isscalar(x));
    addParameter(p, 'HealthyResults', table(), @istable);
    addParameter(p, 'HealthySegmentResults', table(), @istable);
    addParameter(p, 'RunID', "", @(x)ischar(x) || isstring(x));
    addParameter(p, 'WriteResults', true, @(x)islogical(x) && isscalar(x));
    parse(p, varargin{:});

    execute = p.Results.Execute;
    healthy = p.Results.HealthyResults;
    healthySegments = p.Results.HealthySegmentResults;
    runID = string(p.Results.RunID);
    if strlength(runID) == 0
        runID = "SCALABILITY_" + string(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
    end

    runnerDir = fileparts(mfilename('fullpath'));
    repo = fileparts(runnerDir);
    outDir = fullfile(repo, 'results', 'scalability_extension_v1');
    mutationFile = fullfile(repo, 'mutations', '01_Mutation_Set.csv');
    modelFile = fullfile(repo, 'model', 'AS2308_MIL_Baseline_v3.slx');
    specFile = fullfile(outDir, 'candidate_execution_spec_resolved.csv');
    healthyFile = fullfile(outDir, 'healthy_execution_results.csv');
    healthySegmentFile = fullfile(outDir, 'healthy_segment_results.csv');
    finalExecutionFile = fullfile(outDir, 'mutation_execution_results.csv');
    finalMatrixFile = fullfile(outDir, 'mutation_kill_matrix.csv');

    localNeedFile(modelFile, 'baseline model');
    localNeedFile(mutationFile, 'frozen mutation set');
    localNeedFile(specFile, 'resolved execution specification');
    localNeedFile(fullfile(runnerDir, 'run_ai_scalability_suite.m'), 'suite runner');
    mutations = readtable(mutationFile, 'TextType', 'string');
    localValidateMutations(mutations);
    spec = readtable(specFile, 'TextType', 'string');
    localRequireColumns(spec, ["selection_order","extension_candidate_id","requirement_id"]);
    assert(height(spec) == 100, 'run_ai_scalability_mutation_analysis:CandidateCount', ...
        'Resolved execution specification must contain exactly 100 rows.');

    if isempty(healthy)
        localNeedFile(healthyFile, 'healthy execution results');
        healthy = readtable(healthyFile, 'TextType', 'string');
    end
    if isempty(healthySegments)
        localNeedFile(healthySegmentFile, 'healthy segment results');
        healthySegments = readtable(healthySegmentFile, 'TextType', 'string');
    end
    localValidateHealthy(healthy, healthySegments, spec);

    failCount = sum(healthy.status == "FAIL");
    errorCount = sum(healthy.status == "EXECUTION_ERROR");
    inconclusiveCount = sum(healthy.status == "INCONCLUSIVE_PRECONDITION");
    passRows = healthy.status == "PASS";
    passIDs = healthy.extension_candidate_id(passRows);
    gatePassed = failCount == 0 && errorCount == 0;

    localPreflightModel(modelFile, mutations);
    executionTable = table();
    killMatrix = table();
    summary = struct('run_id',runID, 'preflight_pass',true, ...
        'healthy_gate_pass',gatePassed, 'healthy_pass_count',sum(passRows), ...
        'healthy_fail_count',failCount, ...
        'healthy_inconclusive_count',inconclusiveCount, ...
        'healthy_execution_error_count',errorCount, ...
        'valid_mutant_count',height(mutations), ...
        'planned_execution_count',sum(passRows)*height(mutations), ...
        'mutation_elapsed_time_s',0, 'automatic_retry_count',0);

    if ~execute
        fprintf(['Scalability mutation preflight: PASS\n', ...
            'Healthy PASS candidates: %d; planned mutation executions: %d\n', ...
            'No simulation was executed.\n'], sum(passRows), summary.planned_execution_count);
        return
    end
    assert(gatePassed, 'run_ai_scalability_mutation_analysis:HEALTHY_BASELINE_GATE_FAILED', ...
        ['HEALTHY_BASELINE_GATE_FAILED: healthy FAIL=%d, ', ...
         'EXECUTION_ERROR=%d. Mutation was not started.'], failCount, errorCount);
    if p.Results.WriteResults
        assert(~isfile(finalExecutionFile) && ~isfile(finalMatrixFile), ...
            'run_ai_scalability_mutation_analysis:ExistingResult', ...
            'Refusing to overwrite existing scalability mutation results.');
    end

    modelHashBefore = localSha256(modelFile);
    mutationStart = tic;
    rows = table();
    partialFile = fullfile(outDir, "mutation_execution_results_incomplete_" + runID + ".csv");
    for m = 1:height(mutations)
        mutationID = mutations.MutationID(m);
        [mutant, ~, ~] = run_ai_scalability_suite( ...
            'Execute', true, 'MutationID', mutationID, ...
            'WriteResults', false, 'BaselineSegmentResults', healthySegments, ...
            'CandidateIDs', passIDs, 'RunID', runID);
        n = height(mutant);
        block = table(repmat(runID,n,1), repmat(mutationID,n,1), ...
            mutant.ordered_index, mutant.extension_candidate_id, ...
            mutant.requirement_id, repmat("PASS",n,1), mutant.status, ...
            mutant.status == "FAIL", mutant.applicability, ...
            mutant.reversal_setup_status, mutant.elapsed_time_s, ...
            mutant.failure_reason, ...
            'VariableNames', {'run_id','mutation_id','ordered_index', ...
            'extension_candidate_id','requirement_id','healthy_status', ...
            'mutant_status','kill','applicability','reversal_setup_status', ...
            'elapsed_time_s','failure_reason'});
        rows = [rows; block]; %#ok<AGROW>
        writetable(rows, partialFile);
        assert(localSha256(modelFile) == modelHashBefore, ...
            'run_ai_scalability_mutation_analysis:ModelIntegrityFailure', ...
            'On-disk baseline model changed during mutation execution.');
        localAssertBaselineState(modelFile);
    end
    executionTable = rows;
    summary.mutation_elapsed_time_s = toc(mutationStart);
    % Preserve all 100 frozen candidate columns. Healthy non-PASS candidates
    % are explicitly NOT_EXECUTED rather than removed or replaced.
    killMatrix = localBuildKillMatrix(executionTable, mutations, ...
        string(spec.extension_candidate_id));
    if p.Results.WriteResults
        writetable(executionTable, finalExecutionFile);
        writetable(killMatrix, finalMatrixFile);
    end
    fprintf('Scalability mutation analysis completed: %d executions, retry=0.\n', height(rows));
end

function localValidateHealthy(healthy, segments, spec)
    localRequireColumns(healthy, ["run_id","ordered_index","extension_candidate_id", ...
        "requirement_id","status","applicability","reversal_setup_status", ...
        "elapsed_time_s","failure_reason"]);
    localRequireColumns(segments, ["extension_candidate_id","segment_index", ...
        "status","applicability"]);
    assert(height(healthy)==100, 'run_ai_scalability_mutation_analysis:HealthyCount', ...
        'Healthy results must contain the frozen 100 candidates.');
    assert(isequal(string(healthy.extension_candidate_id), string(spec.extension_candidate_id)), ...
        'run_ai_scalability_mutation_analysis:HealthyOrdering', ...
        'Healthy result identity/order differs from the frozen specification.');
    allowed = ["PASS","FAIL","INCONCLUSIVE_PRECONDITION","EXECUTION_ERROR"];
    assert(all(ismember(string(healthy.status),allowed)), ...
        'run_ai_scalability_mutation_analysis:HealthyStatus', 'Unknown healthy status.');
end

function localValidateMutations(t)
    localRequireColumns(t, ["MutationID","MutationName","Target","Status"]);
    expected = "MUT-" + compose('%03d',(1:6)');
    assert(height(t)==6 && isequal(string(t.MutationID),expected), ...
        'run_ai_scalability_mutation_analysis:MutationSet', ...
        'Frozen mutation set must contain ordered MUT-001 through MUT-006.');
    assert(all(string(t.Status)=="Defined - Not Executed"), ...
        'run_ai_scalability_mutation_analysis:MutationStatus', ...
        'Mutation definition status differs from the frozen set.');
    assert(all(contains(string(t.Target),'PI Speed Controller')), ...
        'run_ai_scalability_mutation_analysis:PlantMutation', ...
        'Only PI Speed Controller mutations are allowed.');
end

function localPreflightModel(modelFile, mutations)
    [~,name] = fileparts(modelFile);
    wasLoaded = bdIsLoaded(name);
    load_system(modelFile);
    c = onCleanup(@()localClose(name,wasLoaded)); %#ok<NASGU>
    assert(strcmp(get_param(name,'SolverType'),'Fixed-step'), ...
        'run_ai_scalability_mutation_analysis:SolverType','Model must be fixed-step.');
    assert(strcmp(get_param(name,'Solver'),'ode4'), ...
        'run_ai_scalability_mutation_analysis:Solver','Model solver must be ode4.');
    for k=1:height(mutations)
        target = split(string(mutations.Target(k))," :: ");
        block = char(target(1));
        assert(getSimulinkBlockHandle(block)>0, ...
            'run_ai_scalability_mutation_analysis:MutationTarget', ...
            'Mutation target does not exist: %s', block);
    end
    localAssertBaselineState(modelFile);
end

function localAssertBaselineState(modelFile)
    [~,name] = fileparts(modelFile);
    wasLoaded = bdIsLoaded(name);
    load_system(modelFile);
    c = onCleanup(@()localClose(name,wasLoaded)); %#ok<NASGU>
    assert(strcmp(get_param([name '/PI Speed Controller/Subtract'],'Inputs'),'+-'), ...
        'run_ai_scalability_mutation_analysis:RestoreFailure','Subtract Inputs not restored.');
    assert(strcmp(get_param([name '/PI Speed Controller/Gain'],'Gain'),'Kis'), ...
        'run_ai_scalability_mutation_analysis:RestoreFailure','Integral gain block not restored.');
    sat = [name '/PI Speed Controller/Saturation'];
    assert(strcmp(get_param(sat,'UpperLimit'),'Vdc') && ...
        strcmp(get_param(sat,'LowerLimit'),'-Vdc'), ...
        'run_ai_scalability_mutation_analysis:RestoreFailure','Saturation limits not restored.');
    assert(strcmp(get_param(name,'Dirty'),'off'), ...
        'run_ai_scalability_mutation_analysis:RestoreFailure','Baseline model is dirty.');
end

function matrix = localBuildKillMatrix(rows, mutations, candidateIDs)
    matrix = table(string(mutations.MutationID), 'VariableNames',{'mutation_id'});
    for c=1:numel(candidateIDs)
        id = candidateIDs(c);
        variable = matlab.lang.makeValidName(char(id));
        values = strings(height(mutations),1);
        for m=1:height(mutations)
            hit = rows.mutation_id==mutations.MutationID(m) & rows.extension_candidate_id==id;
            status = rows.mutant_status(hit);
            if isempty(status), values(m)="NOT_EXECUTED";
            elseif status=="FAIL", values(m)="KILL";
            elseif status=="PASS", values(m)="PASS";
            elseif status=="INCONCLUSIVE_PRECONDITION", values(m)="INCONCLUSIVE";
            else, values(m)="EXECUTION_ERROR";
            end
        end
        matrix.(variable)=values;
    end
end

function hash = localSha256(path)
    fid=fopen(path,'rb');
    assert(fid>=0,'run_ai_scalability_mutation_analysis:HashRead','Cannot read %s',path);
    cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
    bytes=fread(fid,Inf,'*uint8');
    md=java.security.MessageDigest.getInstance('SHA-256');
    md.update(typecast(bytes,'int8'));
    hash=lower(string(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[])));
end

function localRequireColumns(t, required)
    missing=setdiff(required,string(t.Properties.VariableNames));
    assert(isempty(missing),'run_ai_scalability_mutation_analysis:MissingColumn', ...
        'Missing required column(s): %s',strjoin(missing,', '));
end

function localNeedFile(path,label)
    assert(isfile(path),'run_ai_scalability_mutation_analysis:MissingDependency', ...
        'Missing %s: %s',label,path);
end

function localClose(name,wasLoaded)
    if ~wasLoaded && bdIsLoaded(name), close_system(name,0); end
end
