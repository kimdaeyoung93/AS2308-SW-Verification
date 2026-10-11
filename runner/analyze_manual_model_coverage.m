function [coverageSummary, uncoveredObjectives, detailData] = ...
        analyze_manual_model_coverage(varargin)
%ANALYZE_MANUAL_MODEL_COVERAGE Measure Manual Suite v1.0 model coverage.
%
%   Measures cumulative structural coverage for the existing nine Manual
%   Dynamic MIL Test Suite v1.0 executions. Test inputs, Oracles, and PASS/
%   FAIL criteria are not changed. Coverage is scoped to the Speed PI
%   Controller subsystem; the plant and top-level support blocks are not
%   included in the reported DUT totals.
%
%   Coverage is a structural adequacy measurement. Full coverage does not
%   demonstrate requirement satisfaction or absence of defects.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'ModelName', 'AS2308_MIL_Baseline_v3', ...
        @(x) (ischar(x) && ~isempty(x)) || ...
        (isstring(x) && isscalar(x) && strlength(x) > 0));
    parse(parser, varargin{:});
    modelName = char(string(parser.Results.ModelName));

    runnerDirectory = fileparts(mfilename('fullpath'));
    repositoryRoot = fileparts(runnerDirectory);
    modelDirectory = fullfile(repositoryRoot, 'model');
    resultsDirectory = fullfile(repositoryRoot, 'results');
    coverageDirectory = fullfile(resultsDirectory, 'coverage');
    modelFile = fullfile(modelDirectory, [modelName, '.slx']);
    parameterScript = fullfile( ...
        modelDirectory, 'AS2308_calculate_pi_control_cc.m');

    assert(isfile(modelFile), 'Model file not found: %s', modelFile);
    assert(isfile(parameterScript), ...
        'Parameter script not found: %s', parameterScript);

    coverageFeature = 'Simulink_Coverage';
    productList = ver;
    coverageInstalled = any(strcmpi( ...
        string({productList.Name}), "Simulink Coverage"));
    coverageLicenseAvailable = license('test', coverageFeature) == 1;
    [coverageLicenseCheckedOut, coverageLicenseMessage] = ...
        license('checkout', coverageFeature);

    fprintf('\nManual Dynamic MIL Test Suite v1.0 Model Coverage\n');
    fprintf('Simulink Coverage installed: %s\n', ...
        localTrueFalse(coverageInstalled));
    fprintf('Coverage license available: %s\n', ...
        localTrueFalse(coverageLicenseAvailable));
    fprintf('Coverage license checkout: %s\n', ...
        localTrueFalse(coverageLicenseCheckedOut == 1));

    if ~coverageInstalled || ~coverageLicenseAvailable || ...
            coverageLicenseCheckedOut ~= 1
        error('analyze_manual_model_coverage:CoverageUnavailable', ...
            ['Simulink Coverage is not usable in this MATLAB installation. ', ...
             'Installed=%d, licenseAvailable=%d, checkout=%d. %s'], ...
            coverageInstalled, coverageLicenseAvailable, ...
            coverageLicenseCheckedOut, coverageLicenseMessage);
    end

    run(parameterScript);
    simulationVariables = struct( ...
        'ts', ts, 'Vdc', Vdc, 'Kps', Kps, 'Kis', Kis, 'Kas', Kas, ...
        'SpeedRef_cmd', 0);

    modelWasLoaded = bdIsLoaded(modelName);
    load_system(modelFile);
    closeModel = onCleanup( ...
        @() localCloseModel(modelName, modelWasLoaded));

    assert(strcmp(get_param(modelName, 'SolverType'), 'Fixed-step'), ...
        'Stored model SolverType must be Fixed-step.');
    assert(strcmp(get_param(modelName, 'Solver'), 'ode4'), ...
        'Stored model Solver must be ode4.');
    assert(strcmp(get_param(modelName, 'FixedStep'), 'ts'), ...
        'Stored model FixedStep must be ts.');
    assert(ts == 0.0004, 'Expected ts = 0.0004 s.');

    dutPath = [modelName, '/PI Speed Controller'];
    dutCoveragePath = '/PI Speed Controller';
    assert(getSimulinkBlockHandle(dutPath) ~= -1, ...
        'DUT subsystem not found: %s', dutPath);

    % cvtest creation verifies that the Coverage engine, not only the
    % license query, is operational before running the nine simulations.
    try
        coverageProbe = cvtest(dutPath, 'Manual Suite v1.0 coverage probe'); %#ok<NASGU>
    catch exception
        error('analyze_manual_model_coverage:CoverageEngineUnavailable', ...
            'Unable to initialize Simulink Coverage for %s: %s', ...
            dutPath, exception.message);
    end

    if ~isfolder(resultsDirectory)
        mkdir(resultsDirectory);
    end
    if ~isfolder(coverageDirectory)
        mkdir(coverageDirectory);
    end

    [simulationInputs, executionInfo] = localBuildManualSuiteInputs( ...
        modelName, simulationVariables, dutCoveragePath, coverageDirectory);
    assert(numel(simulationInputs) == 9, ...
        'Coverage analysis must execute exactly nine top-level runs.');

    metricNames = ["Execution"; "Decision"; "Condition"; "MCDC"];
    metricCount = numel(metricNames);
    executionCount = numel(simulationInputs);
    runCoverage = cell(executionCount, 1);
    cumulativeCoverage = [];
    previousCovered = zeros(metricCount, 1);
    newCoveredByRun = zeros(executionCount, metricCount);
    cumulativeCoveredByRun = zeros(executionCount, metricCount);
    saturationUpperObserved = false(executionCount, 1);
    saturationLowerObserved = false(executionCount, 1);
    saturationUnsaturatedObserved = false(executionCount, 1);

    for executionIndex = 1:executionCount
        fprintf('Coverage run %d/%d: %s %s\n', ...
            executionIndex, executionCount, ...
            executionInfo.TestCaseID(executionIndex), ...
            executionInfo.IterationID(executionIndex));

        simulationOutput = sim(simulationInputs{executionIndex});
        outputNames = string(simulationOutput.who);
        if ~any(outputNames == "covdata")
            error('analyze_manual_model_coverage:MissingCoverageData', ...
                ['Simulation did not return covdata. Confirm that the ', ...
                 'Simulink Coverage product is installed and licensed.']);
        end
        runCoverage{executionIndex} = simulationOutput.get('covdata');

        if executionIndex == 1
            cumulativeCoverage = runCoverage{executionIndex};
        else
            cumulativeCoverage = ...
                cumulativeCoverage + runCoverage{executionIndex};
        end

        currentCovered = zeros(metricCount, 1);
        for metricIndex = 1:metricCount
            [covered, ~, ~, ~] = localMetricInfo( ...
                cumulativeCoverage, dutPath, metricNames(metricIndex));
            currentCovered(metricIndex) = covered;
        end
        newCoveredByRun(executionIndex, :) = ...
            (currentCovered - previousCovered).';
        cumulativeCoveredByRun(executionIndex, :) = currentCovered.';
        previousCovered = currentCovered;

        loggedSignals = simulationOutput.get('logsout');
        rawPiSignal = localGetLoggedSignal(loggedSignals, 'raw_pi_output');
        rawPiOutput = localSignalData(rawPiSignal);
        saturationUpperObserved(executionIndex) = any(rawPiOutput > Vdc);
        saturationLowerObserved(executionIndex) = any(rawPiOutput < -Vdc);
        saturationUnsaturatedObserved(executionIndex) = ...
            any(rawPiOutput > -Vdc & rawPiOutput < Vdc);
    end

    coveredObjectives = zeros(metricCount, 1);
    totalObjectives = zeros(metricCount, 1);
    percentage = NaN(metricCount, 1);
    applicability = strings(metricCount, 1);
    for metricIndex = 1:metricCount
        [coveredObjectives(metricIndex), totalObjectives(metricIndex), ...
            percentage(metricIndex), applicability(metricIndex)] = ...
            localMetricInfo( ...
            cumulativeCoverage, dutPath, metricNames(metricIndex));
    end
    coverageSummary = table( ...
        metricNames, coveredObjectives, totalObjectives, percentage, ...
        applicability, ...
        'VariableNames', {'Metric', 'CoveredObjectives', ...
        'TotalObjectives', 'Percentage', 'Applicability'});

    uncoveredObjectives = localFindUncoveredObjectives( ...
        cumulativeCoverage, dutPath, metricNames);

    contributionTable = executionInfo;
    for metricIndex = 1:metricCount
        metricToken = char(metricNames(metricIndex));
        contributionTable.(['New', metricToken, 'Objectives']) = ...
            newCoveredByRun(:, metricIndex);
        contributionTable.(['Cumulative', metricToken, 'Objectives']) = ...
            cumulativeCoveredByRun(:, metricIndex);
    end

    saturationBehavior = table( ...
        executionInfo.TestCaseID, executionInfo.IterationID, ...
        saturationUpperObserved, saturationLowerObserved, ...
        saturationUnsaturatedObserved, ...
        'VariableNames', {'TestCaseID', 'IterationID', ...
        'UpperSaturationObserved', 'LowerSaturationObserved', ...
        'UnsaturatedRegionObserved'});

    summaryCsv = fullfile( ...
        resultsDirectory, 'manual_suite_v1_coverage_summary.csv');
    uncoveredCsv = fullfile( ...
        resultsDirectory, 'manual_suite_v1_uncovered_objectives.csv');
    contributionCsv = fullfile( ...
        resultsDirectory, 'manual_suite_v1_coverage_contributions.csv');
    reportFile = fullfile( ...
        coverageDirectory, 'manual_suite_v1_coverage.html');
    coverageDataFile = fullfile( ...
        coverageDirectory, 'manual_suite_v1_coverage.cvt');

    writetable(coverageSummary, summaryCsv);
    writetable(uncoveredObjectives, uncoveredCsv);
    writetable(contributionTable, contributionCsv);
    cvsave(coverageDataFile, cumulativeCoverage);
    reportInfo = cvhtml(reportFile, cumulativeCoverage, '-sRT=0');

    detailData = struct( ...
        'dut_path', string(dutPath), ...
        'coverage_api', "SimulationInput + cvdata + cvdata.plus", ...
        'run_coverage', {runCoverage}, ...
        'cumulative_coverage', cumulativeCoverage, ...
        'execution_contributions', contributionTable, ...
        'saturation_behavior', saturationBehavior, ...
        'report_info', reportInfo, ...
        'summary_csv', string(summaryCsv), ...
        'uncovered_csv', string(uncoveredCsv), ...
        'contribution_csv', string(contributionCsv), ...
        'html_report', string(reportFile), ...
        'coverage_data_file', string(coverageDataFile));

    fprintf('\nCumulative DUT coverage:\n');
    disp(coverageSummary);
    fprintf('Uncovered block/metric rows: %d\n', ...
        height(uncoveredObjectives));
    fprintf('Saturation behavior evidence:\n');
    disp(saturationBehavior);
    fprintf(['Coverage is a structural adequacy measurement and does not ', ...
        'demonstrate requirement satisfaction or absence of defects.\n']);
    clear closeModel;
end

function [simulationInputs, executionInfo] = localBuildManualSuiteInputs( ...
        modelName, simulationVariables, dutCoveragePath, coverageDirectory)
    simulationInputs = cell(9, 1);
    TestCaseID = [ ...
        "MTC-001"; "MTC-001"; "MTC-002"; "MTC-002"; ...
        "MTC-003"; "MTC-003"; "MTC-004"; "MTC-004"; "MTC-005"];
    IterationID = [ ...
        "IT-001"; "IT-002"; "IT-001"; "IT-002"; ...
        "IT-001"; "IT-002"; "IT-001"; "IT-002"; "IT-001"];
    TestInput = [ ...
        "+16.75 rps"; "-16.75 rps"; "+2 rps"; "-2 rps"; ...
        "+15 rps"; "-15 rps"; "+15 to -15 rps"; ...
        "-15 to +15 rps"; "+15/-15 rps repeated"];
    executionInfo = table(TestCaseID, IterationID, TestInput);

    constantReferences = [16.75; -16.75; 2; -2; 15; -15];
    for executionIndex = 1:numel(constantReferences)
        simulationInput = localBaseSimulationInput( ...
            modelName, simulationVariables, dutCoveragePath, ...
            coverageDirectory, 1);
        simulationInputs{executionIndex} = simulationInput.setVariable( ...
            'SpeedRef_cmd', constantReferences(executionIndex));
    end

    pulseGenerator = localFindUniqueBlock( ...
        modelName, 'BlockType', 'DiscretePulseGenerator');
    referenceOffset = [modelName, '/Constant2'];
    referenceSwitch = [modelName, '/Manual Switch'];

    initialDirections = [1; -1];
    for reversalIndex = 1:2
        executionIndex = 6 + reversalIndex;
        initialDirection = initialDirections(reversalIndex);
        simulationInput = localBaseSimulationInput( ...
            modelName, simulationVariables, dutCoveragePath, ...
            coverageDirectory, 4);
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'Amplitude', sprintf('%g', 2 * initialDirection));
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'Period', '8');
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'PulseWidth', '25');
        simulationInput = simulationInput.setBlockParameter( ...
            pulseGenerator, 'PhaseDelay', '0');
        simulationInput = simulationInput.setBlockParameter( ...
            referenceOffset, 'Value', sprintf('%g', initialDirection));
        simulationInput = simulationInput.setBlockParameter( ...
            referenceSwitch, 'CurrentSetting', '1');
        simulationInputs{executionIndex} = simulationInput;
    end

    repeatedInput = localBaseSimulationInput( ...
        modelName, simulationVariables, dutCoveragePath, ...
        coverageDirectory, 12);
    repeatedInput = repeatedInput.setBlockParameter( ...
        pulseGenerator, 'Amplitude', '2');
    repeatedInput = repeatedInput.setBlockParameter( ...
        pulseGenerator, 'Period', '4');
    repeatedInput = repeatedInput.setBlockParameter( ...
        pulseGenerator, 'PulseWidth', '50');
    repeatedInput = repeatedInput.setBlockParameter( ...
        pulseGenerator, 'PhaseDelay', '0');
    repeatedInput = repeatedInput.setBlockParameter( ...
        referenceOffset, 'Value', '1');
    repeatedInput = repeatedInput.setBlockParameter( ...
        referenceSwitch, 'CurrentSetting', '1');
    simulationInputs{9} = repeatedInput;
end

function simulationInput = localBaseSimulationInput( ...
        modelName, simulationVariables, dutCoveragePath, ...
        coverageDirectory, stopTime_s)
    simulationInput = Simulink.SimulationInput(modelName);
    variableNames = fieldnames(simulationVariables);
    for variableIndex = 1:numel(variableNames)
        variableName = variableNames{variableIndex};
        simulationInput = simulationInput.setVariable( ...
            variableName, simulationVariables.(variableName));
    end
    simulationInput = simulationInput.setModelParameter( ...
        'StopTime', sprintf('%.17g', stopTime_s), ...
        'SignalLogging', 'on', ...
        'SignalLoggingName', 'logsout', ...
        'SignalLoggingSaveFormat', 'Dataset', ...
        'ReturnWorkspaceOutputs', 'on', ...
        'CovEnable', 'on', ...
        'CovScope', 'Subsystem', ...
        'CovPath', dutCoveragePath, ...
        'CovOutputDir', coverageDirectory, ...
        'CovMetricStructuralLevel', 'MCDC', ...
        'CovSaveSingleToWorkspaceVar', 'on', ...
        'CovSaveName', 'covdata', ...
        'CovNameIncrementing', 'off', ...
        'CovHtmlReporting', 'off');
end

function [covered, total, percentage, applicability] = ...
        localMetricInfo(coverageData, dutPath, metricName)
    switch metricName
        case "Execution"
            metricInfo = executioninfo(coverageData, dutPath);
        case "Decision"
            metricInfo = decisioninfo(coverageData, dutPath);
        case "Condition"
            metricInfo = conditioninfo(coverageData, dutPath);
        case "MCDC"
            metricInfo = mcdcinfo(coverageData, dutPath);
        otherwise
            error('analyze_manual_model_coverage:UnknownMetric', ...
                'Unsupported metric name: %s', metricName);
    end

    if isempty(metricInfo) || numel(metricInfo) < 2 || metricInfo(2) == 0
        covered = 0;
        total = 0;
        percentage = NaN;
        applicability = "N/A";
    else
        covered = metricInfo(1);
        total = metricInfo(2);
        percentage = 100 * covered / total;
        applicability = "Applicable";
    end
end

function uncoveredTable = localFindUncoveredObjectives( ...
        coverageData, dutPath, metricNames)
    blockPaths = find_system(dutPath, ...
        'LookUnderMasks', 'all', 'FollowLinks', 'on', 'Type', 'Block');
    blockPathColumn = strings(0, 1);
    blockTypeColumn = strings(0, 1);
    objectiveTypeColumn = strings(0, 1);
    coveredColumn = zeros(0, 1);
    totalColumn = zeros(0, 1);
    uncoveredColumn = zeros(0, 1);
    missingBehaviorColumn = strings(0, 1);

    for blockIndex = 1:numel(blockPaths)
        blockPath = blockPaths{blockIndex};
        for metricIndex = 1:numel(metricNames)
            metricName = metricNames(metricIndex);
            [covered, total, ~, applicability] = localMetricInfo( ...
                coverageData, blockPath, metricName);
            if applicability == "Applicable" && covered < total
                blockPathColumn(end + 1, 1) = string(blockPath); %#ok<AGROW>
                blockTypeColumn(end + 1, 1) = ...
                    string(get_param(blockPath, 'BlockType')); %#ok<AGROW>
                objectiveTypeColumn(end + 1, 1) = metricName; %#ok<AGROW>
                coveredColumn(end + 1, 1) = covered; %#ok<AGROW>
                totalColumn(end + 1, 1) = total; %#ok<AGROW>
                uncoveredColumn(end + 1, 1) = total - covered; %#ok<AGROW>
                missingBehaviorColumn(end + 1, 1) = ...
                    localMissingBehavior(blockPath, metricName); %#ok<AGROW>
            end
        end
    end

    uncoveredTable = table( ...
        blockPathColumn, blockTypeColumn, objectiveTypeColumn, ...
        coveredColumn, totalColumn, uncoveredColumn, ...
        missingBehaviorColumn, ...
        'VariableNames', {'BlockPath', 'BlockType', 'ObjectiveType', ...
        'CoveredObjectives', 'TotalObjectives', 'UncoveredObjectives', ...
        'MissingBehavior'});
end

function description = localMissingBehavior(blockPath, metricName)
    blockType = string(get_param(blockPath, 'BlockType'));
    if blockType == "Saturate" && metricName == "Decision"
        description = ...
            "One or more upper-saturation, lower-saturation, or " + ...
            "unsaturated decision outcomes were not observed; " + ...
            "inspect the HTML report for the exact outcome.";
    elseif metricName == "Execution"
        description = "Block execution objective was not observed.";
    else
        description = ...
            "One or more " + metricName + ...
            " outcomes were not observed; inspect the HTML report.";
    end
end

function data = localSignalData(signal)
    data = double(squeeze(signal.Data));
    data = data(:);
end

function signal = localGetLoggedSignal(loggedSignals, signalName)
    signalElement = loggedSignals.get(signalName);
    if isempty(signalElement)
        error('analyze_manual_model_coverage:MissingSignal', ...
            'Logged signal "%s" was not found.', signalName);
    end
    signal = signalElement.Values;
end

function blockPath = localFindUniqueBlock(modelName, varargin)
    blocks = find_system(modelName, ...
        'LookUnderMasks', 'all', 'FollowLinks', 'on', varargin{:});
    if numel(blocks) ~= 1
        error('analyze_manual_model_coverage:UnexpectedBlockCount', ...
            'Expected one matching block, found %d.', numel(blocks));
    end
    blockPath = blocks{1};
end

function text = localTrueFalse(value)
    if value
        text = 'true';
    else
        text = 'false';
    end
end

function localCloseModel(modelName, modelWasLoaded)
    if ~modelWasLoaded && bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end
