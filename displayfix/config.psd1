@{
    # EDID product codes of the panel to patch (hex, taken from the monitor's
    # stored EDID). Example: one Dell panel exposes two devnodes, DELA1BD and
    # DELA1BE. Find yours with:
    #   Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
    MonitorIds = @('DELA1BD', 'DELA1BE')

    # Prefix used to find that panel's GraphicsDrivers\Configuration SetIds.
    ConfigurationIdPattern = 'DELA1B'

    # Device instance suffix (for example '4&1cce206c&0&UID4145').
    # Leave empty to auto-detect the devnode that has a stored EDID.
    InstanceSuffix = ''

    # Where transcripts and EDID dumps are written. Empty = this folder.
    BaseDir = ''
}
