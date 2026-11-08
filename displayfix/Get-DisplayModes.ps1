# Prints the current mode of every display and lists any interlaced modes the
# adapter still offers. Verification step for fix-edid.ps1:
#   "INTERLACED modes on \\.\DISPLAYn: NONE - override is live"
[CmdletBinding()]
param(
    [int]$Width = 1920
)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DisplayQuery {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern bool EnumDisplaySettingsEx(string dev, int mode, ref DEVMODE dm, uint flags);
}
'@
foreach ($dn in 1..3) {
  $dev = "\\.\DISPLAY$dn"
  $cur = [DisplayQuery+DEVMODE]::new(); $cur.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($cur)
  if (-not [DisplayQuery]::EnumDisplaySettingsEx($dev, -1, [ref]$cur, 0)) { continue }
  "current ${dev}: {0}x{1} @ {2}Hz interlaced={3}" -f $cur.dmPelsWidth, $cur.dmPelsHeight, $cur.dmDisplayFrequency, [bool]($cur.dmDisplayFlags -band 2) | Write-Host
  if ($cur.dmPelsWidth -ne $Width) { continue }
  $inter = New-Object System.Collections.Generic.List[string]
  $j = 0
  $em = [DisplayQuery+DEVMODE]::new(); $em.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($em)
  while ([DisplayQuery]::EnumDisplaySettingsEx($dev, $j, [ref]$em, 0)) {
    if ($em.dmDisplayFlags -band 2) {
      $tag = "{0}x{1}@{2}i" -f $em.dmPelsWidth, $em.dmPelsHeight, $em.dmDisplayFrequency
      if (-not $inter.Contains($tag)) { $inter.Add($tag) }
    }
    $j++
  }
  Write-Host "INTERLACED modes on ${dev}: $(if ($inter.Count) { $inter -join ', ' } else { 'NONE - override is live' })"
}
