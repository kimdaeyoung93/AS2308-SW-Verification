function [resultTable, detailData] = verify_scalability_stimulus_harness(varargin)
%VERIFY_SCALABILITY_STIMULUS_HARNESS Compare legacy and generic stimuli.
%   Execute=false checks deterministic profile resolution without simulation.
%   Execute=true runs only the three representative infrastructure cases.

    parser = inputParser;
    addParameter(parser, 'Execute', false, ...
        @(x)islogical(x) && isscalar(x));
    parse(parser, varargin{:});
    execute = parser.Results.Execute;

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    sourceModelName = 'AS2308_MIL_Baseline_v3';
    sourceFile = fullfile(repositoryRoot, 'model', ...
        [sourceModelName, '.slx']);
    parameters = localParameters();
    cases = {8; [5, -5]; [6, -6, 6, -6]};
    caseIDs = ["CONSTANT_8"; "TWO_LEVEL_5_NEG5"; ...
        "ALTERNATING_6_NEG6"];
    sourceHashBefore = localSha256(sourceFile);
    harness = scalability_stimulus_harness('create', ...
        sourceFile, parameters.ts);
    cleanupHarness = onCleanup(@()localFinalize( ...
        harness, sourceFile, sourceHashBefore)); %#ok<NASGU>

    rows = repmat(struct('case_id',"", 'input_values',"", ...
        'static_profile_status',"", 'execution_status',"NOT_EXECUTED", ...
        'reference_waveform_equal',NaN, 'vcmd_max_abs_diff_v',NaN, ...
        'motorspeed_max_abs_diff_rps',NaN), numel(cases), 1);
    detailData = repmat(struct('case_id',"", 'baseline',table(), ...
        'harness',table()), numel(cases), 1);

    for index = 1:numel(cases)
        values = double(cases{index}(:).');
        profile = scalability_stimulus_harness('profile', values, 2.0);
        assert(isequal(profile(:, 1), (0:numel(values)-1)' * 2.0));
        assert(isequal(profile(:, 2), values(:)));
        rows(index).case_id = caseIDs(index);
        rows(index).input_values = string(mat2str(values, 17));
        rows(index).static_profile_status = "PASS";
        detailData(index).case_id = caseIDs(index);
    end

    if ~execute
        resultTable = struct2table(rows);
        fprintf(['Scalability stimulus harness static equivalence preflight: PASS\n', ...
            'Representative profiles checked: %d\n', ...
            'Simulation executed: false\n'], numel(cases));
        return;
    end

    sourceWasLoaded = bdIsLoaded(sourceModelName);
    load_system(sourceFile);
    closeSource = onCleanup(@()localCloseSource( ...
        sourceModelName, sourceWasLoaded)); %#ok<NASGU>
    for index = 1:numel(cases)
        values = double(cases{index}(:).');
        baseline = localSimulateBaseline(sourceModelName, values, parameters);
        generic = localSimulateHarness(char(harness.model_name), ...
            values, parameters);
        assert(isequal(baseline.time_s, generic.time_s), ...
            'verify_scalability_stimulus_harness:TimeGridMismatch', ...
            'Baseline and harness time grids differ for %s.', caseIDs(index));
        localVerifyRequestedWaveform(generic.time_s, ...
            generic.reference_rps, values, 2.0);
        referenceEqual = isequal(baseline.reference_rps, ...
            generic.reference_rps);
        assert(referenceEqual, ...
            'verify_scalability_stimulus_harness:ReferenceMismatch', ...
            'Baseline and harness reference waveforms differ for %s.', ...
            caseIDs(index));
        rows(index).execution_status = "PASS";
        rows(index).reference_waveform_equal = referenceEqual;
        rows(index).vcmd_max_abs_diff_v = max(abs( ...
            baseline.Vcmd_v - generic.Vcmd_v));
        rows(index).motorspeed_max_abs_diff_rps = max(abs( ...
            baseline.motorspeed_rps - generic.motorspeed_rps));
        detailData(index).baseline = baseline;
        detailData(index).harness = generic;
    end
    resultTable = struct2table(rows);
    fprintf('Scalability stimulus harness dynamic equivalence: PASS (%d/%d).\n', ...
        sum(resultTable.execution_status == "PASS"), height(resultTable));
end

function samples = localSimulateBaseline(modelName, values, parameters)
    input = localBaseSimulationInput(modelName, parameters);
    input = input.setVariable('SpeedRef_cmd', values(1));
    mainSwitch = [modelName, '/Manual Switch'];
    secondarySwitch = [modelName, '/Manual Switch3'];
    if numel(values) == 1
        input = input.setBlockParameter(mainSwitch, 'CurrentSetting', '0');
        input = input.setBlockParameter(secondarySwitch, 'CurrentSetting', '0');
        input = input.setBlockParameter([modelName, '/Constant3'], ...
            'Value', 'SpeedRef_cmd');
    else
        expected = repmat(values(1:2), 1, ceil(numel(values) / 2));
        assert(isequal(values, expected(1:numel(values))), ...
            'verify_scalability_stimulus_harness:InvalidLegacyCase', ...
            'Legacy comparison supports only representative alternating cases.');
        pulse = find_system(modelName, 'LookUnderMasks', 'all', ...
            'FollowLinks', 'on', 'BlockType', 'DiscretePulseGenerator');
        assert(numel(pulse) == 1);
        input = input.setBlockParameter(pulse{1}, 'Amplitude', ...
            sprintf('%.17g', (values(1) - values(2)) / 15));
        input = input.setBlockParameter(pulse{1}, 'Period', '4');
        input = input.setBlockParameter(pulse{1}, 'PulseWidth', '50');
        input = input.setBlockParameter(pulse{1}, 'PhaseDelay', '0');
        input = input.setBlockParameter(pulse{1}, 'SampleTime', 'ts');
        input = input.setBlockParameter([modelName, '/Constant2'], ...
            'Value', sprintf('%.17g', -values(2) / 15));
        input = input.setBlockParameter(mainSwitch, 'CurrentSetting', '1');
    end
    input = localStopTime(input, numel(values) * 2.0);
    samples = localCollect(sim(input), numel(values) * 2.0);
    localVerifyRequestedWaveform(samples.time_s, ...
        samples.reference_rps, values, 2.0);
end

function samples = localSimulateHarness(modelName, values, parameters)
    input = localBaseSimulationInput(modelName, parameters);
    profile = scalability_stimulus_harness('profile', values, 2.0);
    input = input.setVariable('scalabilitySpeedRefProfile', profile);
    input = input.setBlockParameter([modelName, '/Manual Switch3'], ...
        'CurrentSetting', '0');
    input = input.setBlockParameter([modelName, '/Manual Switch'], ...
        'CurrentSetting', '0');
    input = localStopTime(input, numel(values) * 2.0);
    samples = localCollect(sim(input), numel(values) * 2.0);
end

function input = localBaseSimulationInput(modelName, parameters)
    input = Simulink.SimulationInput(modelName);
    names = fieldnames(parameters);
    for index = 1:numel(names)
        input = input.setVariable(names{index}, parameters.(names{index}));
    end
end

function input = localStopTime(input, stopTime)
    input = input.setModelParameter( ...
        'StopTime', sprintf('%.17g', stopTime), ...
        'SignalLogging', 'on', 'SignalLoggingName', 'logsout', ...
        'SignalLoggingSaveFormat', 'Dataset', ...
        'ReturnWorkspaceOutputs', 'on');
end

function samples = localCollect(output, stopTime)
    logsout = output.get('logsout');
    reference = localSignal(logsout, 'reference');
    speed = localSignal(logsout, 'motorspeed');
    voltage = localSignal(logsout, 'Vcmd');
    time = double(speed.Time(:));
    speedData = double(squeeze(speed.Data));
    speedData = speedData(:);
    referenceData = localAlignSignal(reference, time);
    voltageData = localAlignSignal(voltage, time);
    selected = time < stopTime;
    samples = table(time(selected), ...
        referenceData(selected), speedData(selected), voltageData(selected), ...
        'VariableNames', {'time_s','reference_rps', ...
        'motorspeed_rps','Vcmd_v'});
end

function values = localAlignSignal(signal, targetTime)
    signalTime = double(signal.Time(:));
    data = double(squeeze(signal.Data));
    data = data(:);
    if isequal(signalTime, targetTime)
        values = data;
    else
        values = interp1(signalTime, data, targetTime, 'previous', 'extrap');
    end
end

function signal = localSignal(logsout, name)
    element = logsout.get(name);
    assert(~isempty(element), ...
        'verify_scalability_stimulus_harness:MissingSignal', ...
        'Missing logged signal: %s', name);
    signal = element.Values;
end

function localVerifyRequestedWaveform(time, reference, values, duration)
    for index = 1:numel(values)
        selected = time >= (index - 1) * duration & time < index * duration;
        assert(any(selected));
        tolerance = 64 * eps(max(1, abs(values(index))));
        assert(all(abs(reference(selected) - values(index)) <= tolerance), ...
            'verify_scalability_stimulus_harness:RequestedWaveformMismatch', ...
            'Logged reference differs from requested segment %d.', index);
    end
end

function parameters = localParameters()
    parameters = struct('port_num',7,'ts',0.0004,'Vdc',12,'cpr',4096, ...
        'horizon',20,'pole_pair',7,'a',17.76,'b',2185.96,'f_cs',40);
    parameters.w_cs = 2*pi*parameters.f_cs;
    parameters.Kps = parameters.w_cs/parameters.b;
    parameters.Kis = parameters.a*parameters.Kps;
    parameters.Kas = parameters.Kis/parameters.Kps;
    parameters.f_cp = parameters.f_cs/5;
    parameters.w_cp = 2*pi*parameters.f_cp;
    parameters.Kpp = parameters.w_cp;
end

function localFinalize(harness, sourceFile, expectedHash)
    scalability_stimulus_harness('cleanup', harness);
    assert(localSha256(sourceFile) == expectedHash, ...
        'verify_scalability_stimulus_harness:SourceHashChanged', ...
        'Frozen baseline SHA-256 changed during equivalence check.');
end

function localCloseSource(modelName, wasLoaded)
    if ~wasLoaded && bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end

function hash = localSha256(path)
    fid = fopen(path, 'rb');
    assert(fid >= 0);
    cleanup = onCleanup(@()fclose(fid)); %#ok<NASGU>
    bytes = fread(fid, Inf, '*uint8');
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(typecast(bytes, 'int8'));
    hash = upper(string(reshape( ...
        dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, [])));
end
