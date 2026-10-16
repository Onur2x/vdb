@echo off
crashtest.exe seed 300 137    & call echo == S1 seed300-137 rc=%%ERRORLEVEL%%
crashtest.exe verify          & call echo == V1 rc=%%ERRORLEVEL%%
crashtest.exe seed 300 299    & call echo == S2 seed300-299 rc=%%ERRORLEVEL%%
crashtest.exe verify          & call echo == V2 rc=%%ERRORLEVEL%%
crashtest.exe seed 300 1      & call echo == S3 seed300-1 rc=%%ERRORLEVEL%%
crashtest.exe verify          & call echo == V3 rc=%%ERRORLEVEL%%
crashtest.exe txseed 400 25 260 & call echo == S4 tx400-25-260 rc=%%ERRORLEVEL%%
crashtest.exe verify 25       & call echo == V4 rc=%%ERRORLEVEL%%
crashtest.exe txseed 400 25 251 & call echo == S5 tx400-25-251 rc=%%ERRORLEVEL%%
crashtest.exe verify 25       & call echo == V5 rc=%%ERRORLEVEL%%
crashtest.exe txseed 400 10 395 & call echo == S6 tx400-10-395 rc=%%ERRORLEVEL%%
crashtest.exe verify 10       & call echo == V6 rc=%%ERRORLEVEL%%
crashtest.exe txseed 400 400 200 & call echo == S7 tx400-400-200 rc=%%ERRORLEVEL%%
crashtest.exe verify 400      & call echo == V7 rc=%%ERRORLEVEL%%
crashtest.exe seed 60 60      & call echo == S8 seed60-60 rc=%%ERRORLEVEL%%
crashtest.exe verify          & call echo == V8 rc=%%ERRORLEVEL%%
