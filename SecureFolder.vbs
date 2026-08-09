Dim arg, WSHShell, fsobj, file, link

Set arg = WScript.Arguments
Set WSHShell = WScript.CreateObject("WScript.Shell")
Set fsobj = WScript.CreateObject("Scripting.FileSystemObject")

If arg.Length = 0 Then
WSHShell.Popup "Drag & Drop a folder on this file, else the argument is NULL"
End If

If arg.Length > 0 Then

fsobj.GetFolder(arg(0)).Attributes = 1

Set file = fsobj.OpenTextFile(arg(0) + "\desktop.ini", 2, True)
file.Write "[.ShellClassInfo]" + vbCrLf
file.Write "CLSID2={0AFACED1-E828-11D1-9187-B532F1E9575D}" + vbCrLf
file.Write "Flags=2" + vbCrLf
file.Close

Set link = WSHShell.CreateShortcut(arg(0) + "\target.lnk")
link.TargetPath = arg(0) + "\desktop.ini"
link.Save
End If