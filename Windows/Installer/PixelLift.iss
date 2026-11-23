#define ProductVersion "1.0.0"

[Setup]
AppId={{BF903C42-D66D-4199-AF27-94DD2B17FDC6}
AppName=PixelLift AI
AppVersion={#ProductVersion}
AppPublisher=PixelLift AI
AppPublisherURL=https://github.com/atstti/PixelLift
DefaultDirName={localappdata}\Programs\PixelLift AI
DefaultGroupName=PixelLift AI
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputBaseFilename=PixelLiftAI-Windows-x64-Setup
SetupIconFile=..\PixelLift.Windows\PixelLift.ico
UninstallDisplayIcon={app}\PixelLift.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "デスクトップにショートカットを作成"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\PixelLift AI"; Filename: "{app}\PixelLift.exe"
Name: "{autodesktop}\PixelLift AI"; Filename: "{app}\PixelLift.exe"; Tasks: desktopicon
