function result = run_scalability_extension(varargin)
%RUN_SCALABILITY_EXTENSION Orchestrate the frozen scalability extension.
%   RUN_SCALABILITY_EXTENSION('Execute',false) performs preflight only.

    p=inputParser;
    addParameter(p,'Execute',true,@(x)islogical(x)&&isscalar(x));
    parse(p,varargin{:});
    execute=p.Results.Execute;
    runnerDir=fileparts(mfilename('fullpath'));
    repo=fileparts(runnerDir);
    outDir=fullfile(repo,'results','scalability_extension_v1');
    if ~isfolder(outDir), mkdir(outDir); end
    runID="SCALABILITY_"+string(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
    started=datetime('now','TimeZone','local');

    result=struct('run_id',runID,'execute',execute,'completion_status',"PREFLIGHT_ONLY", ...
        'healthy_results',table(),'healthy_segments',table(), ...
        'mutation_results',table(),'kill_matrix',table());

    if ~execute
        % Each preflight is intentionally called independently. Healthy
        % evidence is created later by the Execute=true workflow.
        failures=strings(0,1);
        try
            verify_scalability_stimulus_harness('Execute',false);
        catch ME
            failures(end+1)=string(ME.identifier)+": "+string(ME.message); %#ok<AGROW>
        end
        try
            run_ai_scalability_suite('Execute',false,'WriteResults',false,'RunID',runID);
        catch ME
            failures(end+1)=string(ME.identifier)+": "+string(ME.message); %#ok<AGROW>
        end
        try
            run_ai_scalability_mutation_analysis('Execute',false, ...
                'RequireHealthyEvidence',false, ...
                'WriteResults',false,'RunID',runID);
        catch ME
            failures(end+1)=string(ME.identifier)+": "+string(ME.message); %#ok<AGROW>
        end
        assert(isempty(failures),'run_scalability_extension:PreflightFailed', ...
            'Scalability extension preflight failed:\n%s',strjoin(failures,newline));
        fprintf('Scalability extension preflight: PASS; simulation executed: false.\n');
        return
    end

    finalFiles={fullfile(outDir,'healthy_execution_results.csv'), ...
        fullfile(outDir,'healthy_segment_results.csv'), ...
        fullfile(outDir,'mutation_execution_results.csv'), ...
        fullfile(outDir,'mutation_kill_matrix.csv'), ...
        fullfile(outDir,'runtime_summary.csv'),fullfile(outDir,'metadata.txt')};
    assert(~any(cellfun(@isfile,finalFiles)), ...
        'run_scalability_extension:ExistingArtifact', ...
        'Refusing to overwrite an existing scalability execution artifact.');

    healthyTimer=tic;
    [healthy,segments]=run_ai_scalability_suite('Execute',true, ...
        'WriteResults',true,'RunID',runID);
    healthyElapsed=toc(healthyTimer);
    result.healthy_results=healthy;
    result.healthy_segments=segments;
    failCount=sum(healthy.status=="FAIL");
    healthyErrors=sum(healthy.status=="EXECUTION_ERROR");
    inconclusiveCount=sum(healthy.status=="INCONCLUSIVE_PRECONDITION");
    if failCount>0 || healthyErrors>0
        completion="HEALTHY_BASELINE_GATE_FAILED";
        mutation=table(); matrix=table(); mutationElapsed=0;
    else
        mutationTimer=tic;
        [mutation,matrix]=run_ai_scalability_mutation_analysis( ...
            'Execute',true,'HealthyResults',healthy, ...
            'HealthySegmentResults',segments,'RunID',runID,'WriteResults',true);
        mutationElapsed=toc(mutationTimer);
        completion="COMPLETED";
    end
    result.mutation_results=mutation;
    result.kill_matrix=matrix;
    result.completion_status=completion;
    totalCount=height(healthy)+height(mutation);
    totalElapsed=healthyElapsed+mutationElapsed;
    if totalCount==0, averageElapsed=NaN; else, averageElapsed=totalElapsed/totalCount; end
    executionErrors=healthyErrors;
    if ~isempty(mutation), executionErrors=executionErrors+sum(mutation.mutant_status=="EXECUTION_ERROR"); end
    runtime=table(runID,height(healthy),height(mutation),totalCount,healthyElapsed, ...
        mutationElapsed,totalElapsed,averageElapsed,failCount,inconclusiveCount, ...
        executionErrors,0,completion,'VariableNames',{'run_id', ...
        'healthy_execution_count','mutation_execution_count','total_execution_count', ...
        'healthy_elapsed_time_s','mutation_elapsed_time_s', ...
        'total_simulation_elapsed_time_s','average_execution_time_s', ...
        'healthy_fail_count','healthy_inconclusive_count','execution_error_count', ...
        'automatic_retry_count','completion_status'});
    writetable(runtime,fullfile(outDir,'runtime_summary.csv'));
    localWriteMetadata(repo,outDir,runID,started,datetime('now','TimeZone','local'),completion);
    fprintf('Scalability extension completion status: %s\n',completion);
end

function localWriteMetadata(repo,outDir,runID,started,ended,status)
    model=fullfile(repo,'model','AS2308_MIL_Baseline_v3.slx');
    mutation=fullfile(repo,'mutations','01_Mutation_Set.csv');
    pool=fullfile(outDir,'candidate_pool_frozen.csv');
    spec=fullfile(outDir,'candidate_execution_spec_resolved.csv');
    [gitStatus,gitText]=system(sprintf('git -C "%s" rev-parse HEAD',repo));
    if gitStatus~=0, gitText='UNAVAILABLE'; end
    [branchStatus,branchText]=system(sprintf('git -C "%s" branch --show-current',repo));
    if branchStatus~=0, branchText='UNAVAILABLE'; end
    simulinkInfo=ver('simulink');
    if isempty(simulinkInfo), simulinkRelease="UNAVAILABLE";
    else, simulinkRelease=string(simulinkInfo.Release); end
    poolTable=readtable(pool,'TextType','string');
    assert(ismember('frozen_pool_sha256',poolTable.Properties.VariableNames), ...
        'run_scalability_extension:PoolHash','Frozen pool hash column is missing.');
    poolHashes=unique(string(poolTable.frozen_pool_sha256));
    assert(numel(poolHashes)==1 && strlength(poolHashes)==64, ...
        'run_scalability_extension:PoolHash','Frozen pool hash is inconsistent.');
    lines=["protocol_version="+localProtocolVersion();"git_commit="+strtrim(string(gitText)); ...
        "branch="+strtrim(string(branchText));"model_hash="+localHash(model); ...
        "mutation_set_hash="+localHash(mutation);"frozen_pool_hash="+poolHashes; ...
        "frozen_pool_file_hash="+localHash(pool); ...
        "execution_spec_hash="+localHash(spec);"matlab_release="+string(version('-release')); ...
        "simulink_release="+simulinkRelease;"ts=0.0004";"solver=ode4"; ...
        "segment_duration_s=2.0";"terminal_window_s=0.05";"run_id="+runID; ...
        "start_timestamp="+string(started,'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'); ...
        "end_timestamp="+string(ended,'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'); ...
        "completion_status="+status;"automatic_retry_count=0"];
    fid=fopen(fullfile(outDir,'metadata.txt'),'wt');
    assert(fid>=0,'run_scalability_extension:MetadataWrite','Cannot write metadata.');
    c=onCleanup(@()fclose(fid)); %#ok<NASGU>
    for k=1:numel(lines)
        fprintf(fid,'%s\n',lines(k));
    end
end

function value=localProtocolVersion()
    value="v1.1 Amended";
end

function h=localHash(path)
    if ~isfile(path), h="MISSING"; return; end
    fid=fopen(path,'rb'); c=onCleanup(@()fclose(fid)); %#ok<NASGU>
    bytes=fread(fid,Inf,'*uint8'); md=java.security.MessageDigest.getInstance('SHA-256');
    md.update(typecast(bytes,'int8'));
    h=lower(string(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[])));
end
