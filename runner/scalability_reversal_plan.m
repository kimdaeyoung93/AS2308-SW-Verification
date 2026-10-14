function plan = scalability_reversal_plan(values)
%SCALABILITY_REVERSAL_PLAN Resolve nonzero plateaus and reversal targets.
%   Zero-reference segments do not change the remembered nonzero sign.

    values = double(values(:).');
    assert(~isempty(values) && all(isfinite(values)), ...
        'scalability_reversal_plan:InvalidValues', ...
        'SpeedRef sequence must contain finite numeric values.');

    segmentSigns = sign(values);
    nonzeroSegments = zeros(1, 0);
    targetSegments = zeros(1, 0);
    previousNonzeroSegments = zeros(1, 0);
    previousSign = 0;
    previousSegment = NaN;

    for segmentIndex = 1:numel(values)
        currentSign = segmentSigns(segmentIndex);
        if currentSign == 0
            continue;
        end
        nonzeroSegments(end + 1) = segmentIndex; %#ok<AGROW>
        if previousSign ~= 0 && currentSign ~= previousSign
            targetSegments(end + 1) = segmentIndex; %#ok<AGROW>
            previousNonzeroSegments(end + 1) = previousSegment; %#ok<AGROW>
        end
        previousSign = currentSign;
        previousSegment = segmentIndex;
    end

    if isempty(nonzeroSegments)
        setupSegment = NaN;
    else
        setupSegment = nonzeroSegments(1);
    end
    plan = struct( ...
        'segment_signs', segmentSigns, ...
        'nonzero_segments', nonzeroSegments, ...
        'setup_segment', setupSegment, ...
        'target_segments', targetSegments, ...
        'previous_nonzero_segments', previousNonzeroSegments);
end
