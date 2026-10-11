function result = evaluate_direction(time, reference, motorspeed, varargin)
%EVALUATE_DIRECTION Evaluate terminal motor-speed direction (ORC-DIR-001).
%
%   RESULT = EVALUATE_DIRECTION(TIME, REFERENCE, MOTORSPEED) evaluates the
%   final 0.05 seconds of the supplied rps signals. Direction matches only
%   when every evaluation sample satisfies:
%       reference .* motorspeed > 0
%
%   RESULT = EVALUATE_DIRECTION(..., 'EvaluationWindow_s', VALUE)
%   overrides the project terminal evaluation window.
%
%   reference_direction and motorspeed_direction use +1 for positive, -1
%   for negative, and 0 when motorspeed has mixed signs or includes zero.
%   The reference must be nonzero and constant in the evaluation window.
%
%   This Oracle evaluates direction only. It does not evaluate tracking
%   accuracy, settling performance, or a minimum speed magnitude. The
%   default 0.05 s window is a project evaluation setting, not a product
%   performance requirement.

    if ~isnumeric(time) || ~isreal(time) || ~isvector(time) || isempty(time)
        error('evaluate_direction:InvalidTime', ...
            'time must be a nonempty real numeric vector.');
    end
    if ~isnumeric(reference) || ~isreal(reference) || ...
            ~isvector(reference) || isempty(reference)
        error('evaluate_direction:InvalidReference', ...
            'reference must be a nonempty real numeric vector.');
    end
    if ~isnumeric(motorspeed) || ~isreal(motorspeed) || ...
            ~isvector(motorspeed) || isempty(motorspeed)
        error('evaluate_direction:InvalidMotorSpeed', ...
            'motorspeed must be a nonempty real numeric vector.');
    end

    time = double(time(:));
    reference = double(reference(:));
    motorspeed = double(motorspeed(:));

    if numel(time) ~= numel(reference) || numel(time) ~= numel(motorspeed)
        error('evaluate_direction:LengthMismatch', ...
            'time, reference, and motorspeed must have the same length.');
    end
    if any(~isfinite(time)) || any(~isfinite(reference)) || ...
            any(~isfinite(motorspeed))
        error('evaluate_direction:NonfiniteInput', ...
            'Input signals must contain only finite values.');
    end
    if any(diff(time) <= 0)
        error('evaluate_direction:InvalidTimeOrder', ...
            'time must be strictly increasing.');
    end

    parser = inputParser;
    parser.FunctionName = mfilename;
    addParameter(parser, 'EvaluationWindow_s', 0.05, ...
        @(x) isnumeric(x) && isreal(x) && isscalar(x) && ...
        isfinite(x) && x > 0);
    parse(parser, varargin{:});
    evaluation_window_s = double(parser.Results.EvaluationWindow_s);

    simulation_duration_s = time(end) - time(1);
    if simulation_duration_s < evaluation_window_s
        error('evaluate_direction:EvaluationWindowTooLong', ...
            ['Simulation duration (%.12g s) is shorter than the ', ...
             'evaluation window (%.12g s).'], ...
            simulation_duration_s, evaluation_window_s);
    end

    evaluation_start_time_s = time(end) - evaluation_window_s;
    evaluation_samples = time >= evaluation_start_time_s;
    evaluation_reference = reference(evaluation_samples);
    evaluation_motorspeed = motorspeed(evaluation_samples);

    if any(evaluation_reference == 0)
        error('evaluate_direction:ZeroTerminalReference', ...
            'reference must be nonzero throughout the evaluation window.');
    end
    if any(evaluation_reference ~= evaluation_reference(1))
        error('evaluate_direction:NonconstantTerminalReference', ...
            'reference must be constant throughout the evaluation window.');
    end

    reference_direction = sign(evaluation_reference(1));
    if all(evaluation_motorspeed > 0)
        motorspeed_direction = 1;
    elseif all(evaluation_motorspeed < 0)
        motorspeed_direction = -1;
    else
        motorspeed_direction = 0;
    end

    sample_direction_match = ...
        evaluation_reference .* evaluation_motorspeed > 0;
    mismatch_sample_count = sum(~sample_direction_match);
    direction_match = all(sample_direction_match);

    result = struct( ...
        'pass', direction_match, ...
        'evaluation_window_s', evaluation_window_s, ...
        'evaluation_start_time_s', evaluation_start_time_s, ...
        'reference_direction', reference_direction, ...
        'motorspeed_direction', motorspeed_direction, ...
        'direction_match', direction_match, ...
        'mismatch_sample_count', mismatch_sample_count);
end
