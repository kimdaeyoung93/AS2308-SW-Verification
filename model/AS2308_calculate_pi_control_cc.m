port_num=7;
ts=0.0004;    % sample time
Vdc=12;       % rated voltage
cpr = 4096;   % counts per revolution = Encoder resolution
horizon= 20;  % design parameter: horizon length for the sliding window
pole_pair=7;  % # of pole pair
a = 17.76;    % model parameter
b=2185.96;    % model parameter
f_cs=40;      % design parameter: bandwidth frequency of the speed loop
w_cs=2*pi*f_cs;     % bandwidth of the speed loop
Kps = w_cs/b;       % proportional gain
Kis = a*Kps;        % integral gain
Kas=Kis/Kps;        % anti-windup feedback gain
f_cp = f_cs/5;      % design parameter: approximate bandwidth frequency the position loop
w_cp = 2*pi*f_cp;   % position loop bandwidth
Kpp=w_cp;           % proportional gain