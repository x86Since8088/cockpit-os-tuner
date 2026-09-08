@echo off
REM deploy.bat - the double-clickable wrapper for deploy.ps1.
REM
REM It contains NO LOGIC, deliberately. docs/DEPLOY-CONTRACT.md section 6.5:
REM "logic in two languages is logic that diverges." Everything this
REM deployment does lives in deploy.ps1; this file exists only so an operator
REM can double-click, and so that %* forwards -InstallTo / -Uninstall / -Remove
REM through unchanged.
REM
REM Cockpit is a Linux service. See the section 1.2 notice deploy.ps1 prints.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
