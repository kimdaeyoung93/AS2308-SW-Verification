function result = evaluate_tracking(time, reference, motorspeed, varargin)
%EVALUATE_TRACKING Evaluate terminal speed-tracking numerical agreement.
%
%   RESULT = EVALUATE_TRACKING(TIME, REFERENCE, MOTORSPEED) evaluates the
%   final 0.05 seconds of the supplied signals. TIME is in seconds, and
%   REFERENCE and MOTORSPEED are in rps.
%
%   RESULT = EVALUATE_TRACKING(..., 'Tolerance_rps', VALUE,
%   'EvaluationWindow_s', VALUE) overrides the default numerical tolerance
%   of 1e-9 rps or the default terminal evaluation window of 0.05 seconds.
%
%   The metric is:
%       max(abs(reference - motorspeed))
%   over samples in the terminal evaluation window. PASS is true when the
%   metric is less than or equal to the tolerance.
%
%   The default tolerance is a project-specific numerical-zero tolerance
%   for the healthy MIL baseline. It is not a product performance
%   requirement or an acceptance threshold derived from the requirements.

    if ~isnumeric(time) || ~isreal(time) || ~isvector(time) || isempty(time)
        error('evaluate_tracking:InvalidTime', ...
            'time must be a nonempty real numeric vector.');
    end
    if ~isnumeric(reference) || ~isreal(reference) || ...
            ~isvector(reference) || isempty(reference)
        error('evaluate_tracking:InvalidReference', ...
            'reference must be a nonempty real numeric vector.');
    end
    if ~isnumeric(motorspeed) || ~isreal(motorspeed) || ...
            ~isvector(motorspeed) || isempty(motorspeed)
        error('evaluate_tracking:InvalidMotorSpeed', ...
            'motorspeed must be a nonempty real numeric vector.');
    end

    time = double(time(:));
    reference = double(reference(:));
    motorspeed = double(motorspeed(:));

    if numel(time) ~= numel(reference) || numel(time) ~= numel(motorspeed)
        error('evaluate_tracking:LengthMismatch', ...
            'time, reference, and motorspeed must have the same length.');
    end
    if any(~isfinite(time)) || any(~isfinite(reference)) || ...
            any(~isfinite(motorspeed))
        error('evaluate_tracking:NonfiniteInput', ...
            'Input signals must contain only finite values.');
    end
    if any(diff(time) <= 0)
        error('evaluate_tracking:InvalidTimeOrder', ...
            'time must be strictly increasing.');
    end

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'Tolerance_rps', 1e-9, ...
        @(x) isnumeric(x) && isreal(x) && isscalar(x) && ...
        isfinite(x) && x >= 0);
    addParameter(parser, 'EvaluationWindow_s', 0.05, ...
        @(x) isnumeric(x) && isreal(x) && isscalar(x) && ...
        isfinite(x) && x > 0);
    parse(parser, varargin{:});

    tolerance_rps = double(parser.Results.Tolerance_rps);
    evaluation_window_s = double(parser.Results.EvaluationWindow_s);
    simulation_duration_s = double(time(end) - time(1));

    if simulation_duration_s < evaluation_window_s
        error('evaluate_tracking:EvaluationWindowTooLong', ...
            ['Simulation duration (%.12g s) is shorter than the ', ...
             'evaluation window (%.12g s).'], ...
            simulation_duration_s, evaluation_window_s);
    end

    evaluation_start_time_s = double(time(end) - evaluation_window_s);
    evaluation_samples = time >= evaluation_start_time_s;
    tracking_error_rps = reference(evaluation_samples) - ...
        motorspeed(evaluation_samples);
    max_abs_error_rps = double(max(abs(tracking_error_rps)));

    result = struct( ...
        'pass', max_abs_error_rps <= tolerance_rps, ...
        'max_abs_error_rps', max_abs_error_rps, ...
        'tolerance_rps', tolerance_rps, ...
        'evaluation_window_s', evaluation_window_s, ...
        'evaluation_start_time_s', evaluation_start_time_s);
end
