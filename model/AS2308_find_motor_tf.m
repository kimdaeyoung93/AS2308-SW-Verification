%-----------------------------------------------------------
% file name : find_motor_tf.m
% After acquiring motor data (voltage, angular velocity, angular acceleration)
% using LW-RCP, this script identifies a first-order motor model
% G(s) = b / (s + a).
% The parameters a and b are estimated using the least squares method.
% Before running this script, the required data must be collected using LW-RCP.
% Run AS2308_BLDC_1st_model.mdl in rapid accelerator mode to collect data,
% and make sure that true_time, theta, and volt are available in the workspace.
% Programmed by Prof. Lee
%-----------------------------------------------------------

ts = 0.0004;        % Sample time
n = length(theta);  % total number of data samples

start = 2/ts;       % start time index
duration = 8/ts;    % number of data samples used for estimation

dtheta = zeros(n,1);    % variable to store angular velocity
ddtheta = zeros(n,1);   % variable to store angular acceleration

% Compute angular velocity of the motor
for i = 3:n-2 % discard the first and last 2 samples
    dtheta(i) = (theta(i+1)-theta(i-1))/(true_time(i+1)-true_time(i-1));
end

% Compute angular acceleration of the motor
for i = 3:n-2 % discard the first and last 2 samples
    ddtheta(i) = (dtheta(i+1)-dtheta(i-1))/(true_time(i+1)-true_time(i-1));
end

% Apply a non-causal filter to obtain angular velocity and acceleration
filt_length = 10; % filter length
dtheta_filt = filtfilt(ones(filt_length,1)/filt_length, 1, dtheta); % filtered angular velocity using a non-causal filter
ddtheta_filt = filtfilt(ones(filt_length,1)/filt_length, 1, ddtheta); % filtered angular acceleration using a non-causal filter

% Least squares parameter estimation using raw data
index_range = start:start+duration;
Y = ddtheta(index_range);
X = [-dtheta(index_range) volt(index_range)];

param=inv(X'*X)*X'*Y; % Using X\Y is numerically more stable
a=param(1);
b=param(2);
fprintf('a=%f, b=%f\n', a, b);

% Least squares parameter estimation using filtered data
Y_filt = ddtheta_filt(index_range);
X_filt = [-dtheta_filt(index_range) volt(index_range)];

param=inv(X_filt'*X_filt)*X_filt'*Y_filt; % Using X_filt\Y_filt is numerically more stable
a_filt=param(1);
b_filt=param(2);
fprintf('a_filt=%f, b_filt=%f\n', a_filt, b_filt);

% Display angular velocity and acceleration
figure(1);
plot(true_time,dot_theta, 'b',true_time,dtheta, 'r', true_time,dtheta_filt,'k'); title('motor angular velocity');
figure(2);
plot(true_time,ddtheta, 'r', true_time,ddtheta_filt,'k'); title('motor angular acceleration');