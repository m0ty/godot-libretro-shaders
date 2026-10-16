@echo off
setlocal
rem Build the Asset Store add-on ZIP. All arguments are passed to the builder.
rem Optional PYTHON must be a Python 3.10+ executable path without arguments.
if defined PYTHON goto configured_python
py -3 -c "import sys; raise SystemExit(sys.version_info < (3, 10))" >nul 2>&1
if not errorlevel 1 goto python_launcher
python -c "import sys; raise SystemExit(sys.version_info < (3, 10))" >nul 2>&1
if not errorlevel 1 goto path_python
echo Python 3.10 or newer is required. Install Python or set PYTHON to its executable path. 1>&2
exit /b 1

:configured_python
"%PYTHON%" -c "import sys; raise SystemExit(sys.version_info < (3, 10))" >nul 2>&1
if errorlevel 1 (
    echo PYTHON must point to a working Python 3.10 or newer executable. 1>&2
    exit /b 1
)
"%PYTHON%" -B "%~dp0addons\retroarch_shaders\tools\build_package.py" --format addon --reuse-identical %*
exit /b %errorlevel%

:python_launcher
py -3 -B "%~dp0addons\retroarch_shaders\tools\build_package.py" --format addon --reuse-identical %*
exit /b %errorlevel%

:path_python
python -B "%~dp0addons\retroarch_shaders\tools\build_package.py" --format addon --reuse-identical %*
exit /b %errorlevel%
