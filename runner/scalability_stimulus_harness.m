function output = scalability_stimulus_harness(action, varargin)
%SCALABILITY_STIMULUS_HARNESS Manage the runtime-only SpeedRef harness.
%   The harness is a temporary copy of the frozen baseline. Only the
%   Constant3 stimulus block is replaced with a From Workspace source.

    action = lower(string(action));
    switch action
        case "create"
            output = localCreate(varargin{:});
        case "cleanup"
            localCleanup(varargin{:});
            output = [];
        case "profile"
            output = localProfile(varargin{:});
        otherwise
            error('scalability_stimulus_harness:UnknownAction', ...
                'Unknown harness action: %s', action);
    end
end

function harness = localCreate(sourceFile, ts)
    arguments
        sourceFile (1, :) char
        ts (1, 1) double {mustBeFinite, mustBePositive}
    end
    assert(isfile(sourceFile), ...
        'scalability_stimulus_harness:MissingSource', ...
        'Frozen baseline model does not exist: %s', sourceFile);
    sourceHashBefore = localSha256(sourceFile);
    [~, sourceModelName] = fileparts(sourceFile);
    sourceWasLoaded = bdIsLoaded(sourceModelName);
    if sourceWasLoaded
        assert(strcmp(get_param(sourceModelName, 'Dirty'), 'off'), ...
            'scalability_stimulus_harness:DirtySource', ...
            'Frozen baseline model is dirty before harness creation.');
    end

    temporaryDirectory = tempname;
    mkdir(temporaryDirectory);
    token = char(java.util.UUID.randomUUID());
    token = regexprep(token, '-', '');
    harnessModelName = ['AS2308_Scalability_Harness_', token(1:12)];
    harnessFile = fullfile(temporaryDirectory, [harnessModelName, '.slx']);
    copyfile(sourceFile, harnessFile, 'f');

    try
        load_system(harnessFile);
        sourceBlock = [harnessModelName, '/Constant3'];
        downstreamSwitch = [harnessModelName, '/Manual Switch3'];
        mainSwitch = [harnessModelName, '/Manual Switch'];
        position = get_param(sourceBlock, 'Position');
        oldPortHandles = get_param(sourceBlock, 'PortHandles');
        oldLine = get_param(oldPortHandles.Outport, 'Line');
        assert(oldLine > 0, ...
            'scalability_stimulus_harness:MissingStimulusLine', ...
            'Constant3 is not connected to the frozen stimulus path.');
        destinationPort = get_param(oldLine, 'DstPortHandle');
        assert(isscalar(destinationPort), ...
            'scalability_stimulus_harness:UnexpectedStimulusBranch', ...
            'Constant3 must have exactly one destination.');
        delete_line(oldLine);
        delete_block(sourceBlock);

        sourceBlock = [harnessModelName, '/Scalability SpeedRef Source'];
        add_block('simulink/Sources/From Workspace', sourceBlock, ...
            'Position', position, ...
            'VariableName', 'scalabilitySpeedRefProfile', ...
            'SampleTime', 'ts', ...
            'Interpolate', 'off', ...
            'OutputAfterFinalValue', 'Holding final value');
        sourcePorts = get_param(sourceBlock, 'PortHandles');
        add_line(harnessModelName, sourcePorts.Outport, destinationPort, ...
            'autorouting', 'on');
        set_param(downstreamSwitch, 'CurrentSetting', '0');
        set_param(mainSwitch, 'CurrentSetting', '0');
        save_system(harnessModelName, harnessFile);
        set_param(harnessModelName, 'Dirty', 'off');
        localValidateHarness(harnessModelName, ts);
    catch exception
        localCleanup(struct( ...
            'model_name', string(harnessModelName), ...
            'model_file', string(harnessFile), ...
            'temporary_directory', string(temporaryDirectory)));
        rethrow(exception);
    end

    sourceHashAfter = localSha256(sourceFile);
    assert(sourceHashAfter == sourceHashBefore, ...
        'scalability_stimulus_harness:SourceHashChanged', ...
        'Frozen baseline SHA-256 changed during harness creation.');
    if sourceWasLoaded
        assert(strcmp(get_param(sourceModelName, 'Dirty'), 'off'), ...
            'scalability_stimulus_harness:DirtySource', ...
            'Frozen baseline model became dirty during harness creation.');
    else
        assert(~bdIsLoaded(sourceModelName), ...
            'scalability_stimulus_harness:SourceLoadStateChanged', ...
            'Frozen baseline model load state changed during harness creation.');
    end

    harness = struct( ...
        'model_name', string(harnessModelName), ...
        'model_file', string(harnessFile), ...
        'temporary_directory', string(temporaryDirectory), ...
        'source_file', string(sourceFile), ...
        'source_sha256', sourceHashBefore, ...
        'sample_time_s', ts, ...
        'source_block', string(sourceBlock));
end

function profile = localProfile(values, segmentDuration)
    values = double(values(:));
    assert(~isempty(values) && all(isfinite(values)), ...
        'scalability_stimulus_harness:InvalidValues', ...
        'SpeedRef sequence must contain finite numeric values.');
    assert(isscalar(segmentDuration) && isfinite(segmentDuration) && ...
        segmentDuration > 0, ...
        'scalability_stimulus_harness:InvalidSegmentDuration', ...
        'Segment duration must be a positive finite scalar.');
    time = (0:numel(values)-1)' * segmentDuration;
    profile = [time, values];
end

function localValidateHarness(modelName, ts)
    sourceBlock = [modelName, '/Scalability SpeedRef Source'];
    assert(strcmp(get_param(sourceBlock, 'BlockType'), 'FromWorkspace'));
    assert(strcmp(get_param(sourceBlock, 'VariableName'), ...
        'scalabilitySpeedRefProfile'));
    assert(strcmp(get_param(sourceBlock, 'SampleTime'), 'ts'));
    assert(strcmp(get_param(sourceBlock, 'Interpolate'), 'off'));
    assert(strcmp(get_param(sourceBlock, 'OutputAfterFinalValue'), ...
        'Holding final value'));
    assert(ts == 0.0004);
    assert(strcmp(get_param([modelName, '/Manual Switch3'], ...
        'CurrentSetting'), '0'));
    assert(strcmp(get_param([modelName, '/Manual Switch'], ...
        'CurrentSetting'), '0'));

    sourcePorts = get_param(sourceBlock, 'PortHandles');
    line = get_param(sourcePorts.Outport, 'Line');
    destination = get_param(line, 'DstBlockHandle');
    assert(isscalar(destination) && ...
        strcmp(getfullname(destination), [modelName, '/Manual Switch3']), ...
        'scalability_stimulus_harness:UnexpectedHarnessTopology', ...
        'Generic source must feed only Manual Switch3.');
    mainPorts = get_param([modelName, '/Manual Switch'], 'PortHandles');
    mainLine = get_param(mainPorts.Outport, 'Line');
    mainDestination = get_param(mainLine, 'DstBlockHandle');
    assert(isscalar(mainDestination) && ...
        strcmp(getfullname(mainDestination), [modelName, '/Gain2']), ...
        'scalability_stimulus_harness:UnexpectedHarnessTopology', ...
        'Frozen Manual Switch downstream must remain connected to Gain2.');
    assert(getSimulinkBlockHandle([modelName, '/PI Speed Controller']) > 0);
    assert(getSimulinkBlockHandle([modelName, '/Transfer Fcn2']) > 0);
end

function localCleanup(harness)
    if isfield(harness, 'model_name')
        modelName = char(harness.model_name);
        if bdIsLoaded(modelName)
            close_system(modelName, 0);
        end
    end
    if ~isfield(harness, 'temporary_directory')
        return;
    end
    directory = char(harness.temporary_directory);
    normalizedTemp = char(java.io.File(tempdir).getCanonicalPath());
    normalizedTarget = char(java.io.File(directory).getCanonicalPath());
    assert(startsWith(normalizedTarget, [normalizedTemp, filesep], ...
        'IgnoreCase', true), ...
        'scalability_stimulus_harness:UnsafeCleanupTarget', ...
        'Refusing to remove unexpected directory: %s', normalizedTarget);
    if isfolder(normalizedTarget)
        rmdir(normalizedTarget, 's');
    end
end

function hash = localSha256(path)
    fid = fopen(path, 'rb');
    assert(fid >= 0, 'scalability_stimulus_harness:HashRead', ...
        'Cannot read file for SHA-256: %s', path);
    cleanup = onCleanup(@()fclose(fid)); %#ok<NASGU>
    bytes = fread(fid, Inf, '*uint8');
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(typecast(bytes, 'int8'));
    hash = upper(string(reshape( ...
        dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, [])));
end
