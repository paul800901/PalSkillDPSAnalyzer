Option Explicit

If WScript.Arguments.Count = 1 Then
    If LCase(CStr(WScript.Arguments(0))) = "--validate" Then
        WScript.Quit 0
    End If
End If

If WScript.Arguments.Count <> 0 And WScript.Arguments.Count <> 6 Then
    WScript.Quit 2
End If

Function QuoteArgument(ByVal value)
    QuoteArgument = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

Dim shell, fileSystem, scriptDirectory
Dim powershellPath, overlayPath, statePath, commandPath, heartbeatPath, logPath
Dim command
Set shell = CreateObject("WScript.Shell")
If WScript.Arguments.Count = 0 Then
    Set fileSystem = CreateObject("Scripting.FileSystemObject")
    scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
    powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
    overlayPath = fileSystem.BuildPath(scriptDirectory, "skill_dps_overlay.ps1")
    statePath = fileSystem.BuildPath(scriptDirectory, "skill_dps_hud_state.txt")
    commandPath = fileSystem.BuildPath(scriptDirectory, "skill_dps_hud_command.txt")
    heartbeatPath = fileSystem.BuildPath(scriptDirectory, "skill_dps_hud_heartbeat.txt")
    logPath = fileSystem.BuildPath(scriptDirectory, "skill_dps_hud_overlay.log")
Else
    powershellPath = WScript.Arguments(0)
    overlayPath = WScript.Arguments(1)
    statePath = WScript.Arguments(2)
    commandPath = WScript.Arguments(3)
    heartbeatPath = WScript.Arguments(4)
    logPath = WScript.Arguments(5)
End If

command = QuoteArgument(powershellPath) _
    & " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -STA" _
    & " -File " & QuoteArgument(overlayPath) _
    & " -StatePath " & QuoteArgument(statePath) _
    & " -CommandPath " & QuoteArgument(commandPath) _
    & " -HeartbeatPath " & QuoteArgument(heartbeatPath) _
    & " -LogPath " & QuoteArgument(logPath)

' Window style 0 starts the long-running WPF overlay without a console window.
' The launcher returns immediately so UE4SS never owns or waits on that process.
shell.Run command, 0, False
