# Set up a fresh Windows with Microsoft's Windows Developer Config (github.com/microsoft/WindowsDeveloperConfig, MIT).
# Nothing from that repo is copied into this app: each run downloads Microsoft's own script, checks that it carries a
# valid Microsoft signature, then runs it in its own window (setups can be interactive and may restart the PC).
# Dot-sourced by rescue.ps1. Runs in a working Windows only, not on the rescue USB.
#   devconfig -Option list          the setups
#   devconfig -Option <id>          run one, e.g. standard, local-ai-ollama, python

$DevBase = 'https://aka.ms/devconfig'
$DevRaw  = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/Workloads'
# id, what it is, script path under aka.ms/devconfig  OR  winget:<Workloads folder>
$DevFlows = @(
  @('standard',          'Full dev workstation, standard: tools, Windows settings, WSL + Ubuntu, terminal (may restart)', 'standard/setup.ps1'),
  @('full',              'Full dev workstation, full experience (may restart)',                                            'full/setup.ps1'),
  @('wsl-comfort',       'Nicer WSL shell: zsh/bash, Starship, CLI tools, themed terminal (asks as it goes)',               'wsl-comfort/setup.ps1'),
  @('local-ai',          'Local AI: PyTorch matched to your GPU (CUDA, ROCm, Intel or CPU), tested',                        'local-ai/setup.ps1'),
  @('local-ai-ollama',   'Local AI + Ollama',                                                                               'local-ai/ollama/setup.ps1'),
  @('local-ai-llamacpp', 'Local AI + llama.cpp',                                                                            'local-ai/llama.cpp/setup.ps1'),
  @('local-ai-foundry',  'Local AI + Foundry Local',                                                                        'local-ai/foundry/setup.ps1'),
  @('pytorch',           'PyTorch only (CPU, CUDA, ROCm or Intel XPU) in its own venv',                                     'pytorch/setup.ps1'),
  @('cuda',              'NVIDIA CUDA Toolkit + MSVC, compiles a test kernel (needs the NVIDIA driver first)',              'cuda/setup.ps1'),
  @('rocm',              'AMD ROCm / HIP SDK, compiles a test kernel (supported AMD GPUs)',                                 'rocm/setup.ps1'),
  @('intel-ai',          'Intel AI: OpenVINO, optional oneAPI/SYCL',                                                         'intel-ai/setup.ps1'),
  @('llama.cpp',         'llama.cpp only, the build for your GPU + a small test model',                                     'llama.cpp/setup.ps1'),
  @('ollama',            'Ollama only + a small test model',                                                                'ollama/setup.ps1'),
  @('foundry',           'Foundry Local only + a small test model (Windows 11 24H2 or later)',                              'foundry/setup.ps1'),
  @('dotnet',            '.NET',      'dotnet/setup.ps1'),
  @('winui',             'WinUI 3',   'winui/setup.ps1'),
  @('winforms',          'WinForms',  'winforms/setup.ps1'),
  @('winappcli',         'WinAppCLI', 'winappcli/setup.ps1'),
  @('go',                'Go',        'go/setup.ps1'),
  @('rust',              'Rust',      'rust/setup.ps1'),
  @('php',               'PHP',       'php/setup.ps1'),
  @('python',            'Python',     'winget:python'),
  @('typescript',        'TypeScript', 'winget:typescript'),
  @('java',              'Java',       'winget:java'),
  @('sql',               'SQL',        'winget:sql'),
  @('powershell',        'PowerShell', 'winget:powershell'),
  @('uninstall',         'UNDO the standard/full workstation setup: deletes Ubuntu and its files, removes the tools (even ones you had before)', 'standard/uninstall.ps1')
)

function Cmd-DevConfig {
  if (-not $Option -or $Option -eq 'list') {
    Head 'Windows Developer Config setups (Microsoft)'
    foreach ($f in $DevFlows) { Say ("FLOW|{0}|{1}" -f $f[0], $f[1]) }
    Say 'END'
    return
  }
  if ($env:SystemDrive -eq 'X:') { throw 'This sets up a working Windows. Sign in to Windows (the fresh one) and run it there.' }
  $f = $DevFlows | Where-Object { $_[0] -eq $Option } | Select-Object -First 1
  if (-not $f) { throw "Unknown setup '$Option'. Use devconfig -Option list." }
  if ($f[0] -eq 'uninstall') {
    Say 'This removes Ubuntu with everything inside it, and the tools the setup installs, including copies you installed yourself.'
    Say 'Your old settings are not put back. Back up anything inside WSL first.'
    if (-not (Confirm-Action 'Really undo the workstation setup?')) { Say 'Cancelled.'; return }
  }
  elseif (-not (Confirm-Action "Run Microsoft's '$($f[1])' setup? It installs software and may restart this PC.")) { Say 'Cancelled.'; return }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $work = Join-Path $env:TEMP "violet-devconfig\$($f[0])"
  New-Item -ItemType Directory -Force $work | Out-Null

  if ($f[2] -like 'winget:*') {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget is missing. Install "App Installer" from the Microsoft Store first.' }
    $folder = $f[2].Substring(7)
    $cfg = Join-Path $work 'configuration.winget'
    Say "Downloading $DevRaw/$folder/configuration.winget"
    Invoke-WebRequest "$DevRaw/$folder/configuration.winget" -OutFile $cfg -UseBasicParsing
    # The repo's troubleshooting: 'configure' must be enabled first, and it needs the VC++ runtime.
    Say 'Opening winget configure in its own window...'
    $cmd = "winget configure --enable; " +
           "winget install --id Microsoft.VCRedist.2015+.x64 --silent --accept-package-agreements --accept-source-agreements; " +
           "winget configure -f '$cfg' --accept-configuration-agreements --disable-interactivity"
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoExit', '-Command', $cmd
    return
  }

  $url = "$DevBase/$($f[2])"
  $file = Join-Path $work 'setup.ps1'
  Say "Downloading $url"
  Invoke-WebRequest $url -OutFile $file -UseBasicParsing
  $sig = Get-AuthenticodeSignature $file
  $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { 'none' }
  Say "Signature: $($sig.Status), signer: $signer"
  if ($sig.Status -ne 'Valid' -or $signer -notmatch 'O=Microsoft Corporation') {
    throw 'The downloaded script is not validly signed by Microsoft, so it was not run.'
  }
  Say 'Signed by Microsoft. Opening it in its own window...'
  Start-Process powershell.exe -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$file`""
}
