function results = characterize_tracking_oracle(varargin)
%CHARACTERIZE_TRACKING_ORACLE Characterize terminal tracking residuals.
%
%   RESULTS = CHARACTERIZE_TRACKING_ORACLE() uses the current default
%   baseline model AS2308_MIL_Baseline_v3.
%
%   RESULTS = CHARACTERIZE_TRACKING_ORACLE('ModelName', MODELNAME) runs the
%   same references, windows, and metrics against the selected model.

%% Tracking Oracle Baseline Characterization
% Healthy MIL baseline에서 terminal tracking residual을 측정한다.
% 이 결과는 제품 성능 요구사항이 아니라
% Tracking Oracle의 numerical tolerance / evaluation window 결정을 위한
% baseline characterization data로 사용한다.

parser = inputParser;
parser.FunctionName = mfilename;
addParameter(parser, 'ModelName', 'AS2308_MIL_Baseline_v3', ...
    @(x) (ischar(x) && ~isempty(x)) || ...
    (isstring(x) && isscalar(x) && strlength(x) > 0));
parse(parser, varargin{:});
model = char(string(parser.Results.ModelName));

%% 1. Project path 설정
runnerDir   = fileparts(mfilename("fullpath"));
projectRoot = fileparts(runnerDir);
modelDir    = fullfile(projectRoot, "model");

addpath(modelDir);

%% 2. Baseline controller parameter 초기화
% Kps, Kis, Kas, a, b, Vdc, ts 등을 workspace에 생성
run(fullfile(modelDir, "AS2308_calculate_pi_control_cc.m"));

%% 3. Model 설정
modelFile = fullfile(modelDir, [model, '.slx']);
assert(isfile(modelFile), 'Model file not found: %s', modelFile);
load_system(modelFile);

simulationVariables = struct( ...
    'ts', ts, 'Vdc', Vdc, 'Kps', Kps, 'Kis', Kis, 'Kas', Kas);

%% 4. Characterization 조건

% Constant Speed Reference [rps]
refs = [2, -2, 15, -15];

% Terminal evaluation window 후보 [s]
windows = [0.05, 0.10, 0.20, 0.50];

% Characterization용 simulation time [s]
stopTime = 1.0;

%% 5. 결과 저장 변수
result_ref         = [];
result_window      = [];
result_final_error = [];
result_max_error   = [];
result_mean_error  = [];

fprintf("\n");
fprintf("========================================\n");
fprintf(" Tracking Oracle Baseline Characterization\n");
fprintf(" Model : %s\n", model);
fprintf(" Stop Time : %.2f s\n", stopTime);
fprintf("========================================\n");

%% 6. Reference별 simulation 실행
for k = 1:length(refs)

    r = refs(k);

    %% Simulation input 구성
    simIn = Simulink.SimulationInput(model);

    variableNames = fieldnames(simulationVariables);
    for variableIndex = 1:numel(variableNames)
        variableName = variableNames{variableIndex};
        simIn = simIn.setVariable( ...
            variableName, simulationVariables.(variableName));
    end

    % Simulink Constant block에서 사용하는 변수
    simIn = simIn.setVariable("SpeedRef_cmd", r);

    % Simulation duration
    simIn = simIn.setModelParameter( ...
        "StopTime", num2str(stopTime));

    %% Simulation
    simOut = sim(simIn);

    %% Logged signal 획득
    logs = simOut.logsout;

    refSig = logs.get("reference");
    spdSig = logs.get("motorspeed");

    % Signal 존재 여부 확인
    if isempty(refSig)
        error("Logged signal 'reference'를 찾을 수 없습니다.");
    end

    if isempty(spdSig)
        error("Logged signal 'motorspeed'를 찾을 수 없습니다.");
    end

    %% Timeseries 데이터 획득
    refTS = refSig.Values;
    spdTS = spdSig.Values;

    % MotorSpeed의 time vector를 기준으로 평가
    t = double(spdTS.Time(:));
    motorSpeed = double(squeeze(spdTS.Data));
    motorSpeed = motorSpeed(:);

    % Reference signal을 동일 time vector로 정렬
    refTime = double(refTS.Time(:));
    refData = double(squeeze(refTS.Data));
    refData = refData(:);

    if isequal(t, refTime)

        reference = refData;

    else

        reference = interp1( ...
            refTime, ...
            refData, ...
            t, ...
            "previous", ...
            "extrap");

    end

    %% Tracking error
    trackingError = reference - motorSpeed;

    finalError = abs(trackingError(end));

    %% 출력
    fprintf("\n");
    fprintf("----------------------------------------\n");
    fprintf(" SpeedRef = %+6.2f rps\n", r);
    fprintf("----------------------------------------\n");

    fprintf( ...
        "Final error = %.12e rps\n", ...
        finalError);

    %% 각 candidate evaluation window 분석
    for j = 1:length(windows)

        W = windows(j);

        evalIdx = t >= (t(end) - W);

        maxError = max(abs(trackingError(evalIdx)));
        meanError = mean(abs(trackingError(evalIdx)));

        fprintf( ...
            "Last %.2f s | Max = %.12e rps | Mean = %.12e rps\n", ...
            W, ...
            maxError, ...
            meanError);

        %% 결과 누적
        result_ref(end+1,1)         = r;
        result_window(end+1,1)      = W;
        result_final_error(end+1,1) = finalError;
        result_max_error(end+1,1)   = maxError;
        result_mean_error(end+1,1)  = meanError;

    end
end

%% 7. Summary table 생성
results = table( ...
    result_ref, ...
    result_window, ...
    result_final_error, ...
    result_max_error, ...
    result_mean_error, ...
    'VariableNames', { ...
        'SpeedRef_rps', ...
        'Window_s', ...
        'FinalError_rps', ...
        'MaxAbsError_rps', ...
        'MeanAbsError_rps'});

fprintf("\n");
fprintf("========================================\n");
fprintf(" Summary\n");
fprintf("========================================\n");

disp(results);

fprintf("\n");
fprintf("NOTE:\n");
fprintf("이 결과는 제품 성능 Requirement가 아니라\n");
fprintf("Tracking Oracle의 numerical criterion 결정을 위한\n");
fprintf("Healthy MIL baseline characterization 결과입니다.\n");
end
