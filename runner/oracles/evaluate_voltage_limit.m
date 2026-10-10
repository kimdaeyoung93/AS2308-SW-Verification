function result = evaluate_voltage_limit(time, Vcmd, voltage_limit)
%EVALUATE_VOLTAGE_LIMIT Evaluate Vcmd against the symmetric voltage limit.
%
%   RESULT = EVALUATE_VOLTAGE_LIMIT(TIME, VCMD) evaluates all supplied
%   samples against the REQ-VOLT-001 limits of -12 V and +12 V.
%
%   RESULT = EVALUATE_VOLTAGE_LIMIT(TIME, VCMD, VOLTAGE_LIMIT) uses the
%   supplied positive symmetric voltage limit instead of the default 12 V.
%
%   PASS is true only when every Vcmd sample satisfies:
%       -VOLTAGE_LIMIT <= Vcmd <= +VOLTAGE_LIMIT
%
%   No numerical tolerance is applied. raw_pi_output is not an input to
%   this Oracle and is not used for the REQ-VOLT-001 PASS/FAIL decision.

    narginchk(2, 3);

    if nargin < 3
        voltage_limit = 12;
    end

    if ~isnumeric(time) || ~isreal(time) || ~isvector(time) || isempty(time)
        error('evaluate_voltage_limit:InvalidTime', ...
            'time must be a nonempty real numeric vector.');
    end
    if ~isnumeric(Vcmd) || ~isreal(Vcmd) || ~isvector(Vcmd) || isempty(Vcmd)
        error('evaluate_voltage_limit:InvalidVcmd', ...
            'Vcmd must be a nonempty real numeric vector.');
    end
    if ~isnumeric(voltage_limit) || ~isreal(voltage_limit) || ...
            ~isscalar(voltage_limit) || ~isfinite(voltage_limit) || ...
            voltage_limit <= 0
        error('evaluate_voltage_limit:InvalidVoltageLimit', ...
            'voltage_limit must be a positive finite real numeric scalar.');
    end

    time = double(time(:));
    Vcmd = double(Vcmd(:));
    voltage_limit = double(voltage_limit);

    if numel(time) ~= numel(Vcmd)
        error('evaluate_voltage_limit:LengthMismatch', ...
            'time and Vcmd must have the same length.');
    end
    if any(~isfinite(time)) || any(~isfinite(Vcmd))
        error('evaluate_voltage_limit:NonfiniteInput', ...
            'time and Vcmd must contain only finite values.');
    end
    if any(diff(time) <= 0)
        error('evaluate_voltage_limit:InvalidTimeOrder', ...
            'time must be strictly increasing.');
    end

    upper_limit_v = voltage_limit;
    lower_limit_v = -voltage_limit;
    max_vcmd_v = max(Vcmd);
    min_vcmd_v = min(Vcmd);
    max_upper_exceedance_v = max(0, max_vcmd_v - upper_limit_v);
    max_lower_exceedance_v = max(0, lower_limit_v - min_vcmd_v);

    result = struct( ...
        'pass', max_vcmd_v <= upper_limit_v && min_vcmd_v >= lower_limit_v, ...
        'max_vcmd_v', max_vcmd_v, ...
        'min_vcmd_v', min_vcmd_v, ...
        'upper_limit_v', upper_limit_v, ...
        'lower_limit_v', lower_limit_v, ...
        'max_upper_exceedance_v', max_upper_exceedance_v, ...
        'max_lower_exceedance_v', max_lower_exceedance_v);
end
