@{
    # EDID Short Monitor ID of the external panel. Get it from
    #   MultiMonitorTool.exe /scomma monitors.csv
    # Example: a Dell panel reports DELA1BE.
    ShortId = 'DELA1BE'

    # This machine's own input on that panel.
    # 15 = DisplayPort1, 17 = HDMI1, 18 = HDMI2
    OwnInput = 18

    # Log file. Empty = switch.log next to the scripts.
    LogPath = ''
}
