function result = self_check_tracking()
%SELF_CHECK_TRACKING Confirm that a healthy-baseline-scale residual passes.
%
%   This self-check uses a logged-signal-shaped example with a terminal
%   residual of approximately 1e-14 rps, matching the numerical scale seen
%   in healthy AS2308 MIL baseline characterization.

    time = (0:0.001:1).';
    reference = 15 * ones(size(time));
    motorspeed = reference;

    terminal_samples = time >= time(end) - 0.05;
    motorspeed(terminal_samples) = reference(terminal_samples) - 1e-14;

    result = evaluate_tracking(time, reference, motorspeed);

    assert(result.pass, ...
        'self_check_tracking:ExpectedPass', ...
        'Healthy-baseline-scale tracking signal did not pass.');

    fprintf(['Tracking Oracle self-check PASS: max abs error = %.12g rps, ', ...
        'tolerance = %.12g rps\n'], ...
        result.max_abs_error_rps, result.tolerance_rps);
end
