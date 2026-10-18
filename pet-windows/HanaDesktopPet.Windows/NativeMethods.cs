using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace HanaDesktopPet.Windows
{
    internal static class NativeMethods
    {
        internal const int GwlExStyle = -20;
        internal const int WsExToolWindow = 0x00000080;
        internal const int WsExNoActivate = 0x08000000;
        internal const int MaNoActivate = 3;
        internal const int HtClient = 1;
        internal const uint SwpNoSize = 0x0001;
        internal const uint SwpNoMove = 0x0002;
        internal const uint SwpNoZOrder = 0x0004;
        internal const uint SwpNoActivate = 0x0010;
        internal const uint SwpFrameChanged = 0x0020;
        internal const uint MonitorDefaultToNearest = 2;
        internal const uint MonitorDefaultToPrimary = 1;
        internal const uint SpiGetClientAreaAnimation = 0x1042;
        internal const uint MfString = 0x00000000;
        internal const uint MfGrayed = 0x00000001;
        internal const uint MfChecked = 0x00000008;
        internal const uint MfSeparator = 0x00000800;
        internal const uint MfPopup = 0x00000010;
        internal const uint TpmRightButton = 0x0002;
        internal const uint TpmNonotify = 0x0080;
        internal const uint TpmRetcmd = 0x0100;
        internal const uint TpmNoanimation = 0x4000;

        internal static readonly IntPtr HwndTopmost = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential)]
        internal struct Point
        {
            public int X;
            public int Y;
            public Point(int x, int y) { X = x; Y = y; }
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct Rect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
            public int Width { get { return Right - Left; } }
            public int Height { get { return Bottom - Top; } }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct MonitorInfoEx
        {
            public uint Size;
            public Rect Monitor;
            public Rect Work;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string Device;
        }

        internal sealed class MonitorArea
        {
            public IntPtr Handle;
            public string Device;
            public Rect Work;
            public bool IsPrimary;
        }

        private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
        private static extern int GetWindowLong(IntPtr hwnd, int index);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
        private static extern int SetWindowLong(IntPtr hwnd, int index, int value);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetCursorPos(out Point point);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll")]
        internal static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

        [DllImport("user32.dll")]
        internal static extern IntPtr MonitorFromPoint(Point point, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMonitorInfoW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfoEx info);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clipRect, MonitorEnumProc callback, IntPtr data);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool IsWindowVisible(IntPtr hwnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool IsIconic(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SystemParametersInfo(uint action, uint parameter, ref bool value, uint flags);

        [DllImport("user32.dll", EntryPoint = "GetDpiForWindow", SetLastError = true)]
        private static extern uint GetDpiForWindowNative(IntPtr hwnd);

        [DllImport("shcore.dll", EntryPoint = "GetDpiForMonitor", SetLastError = true)]
        private static extern int GetDpiForMonitorNative(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreatePopupMenu", SetLastError = true)]
        internal static extern IntPtr CreatePopupMenu();

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "AppendMenuW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AppendMenu(IntPtr menu, uint flags, IntPtr item, string text);

        [DllImport("user32.dll", EntryPoint = "TrackPopupMenuEx", SetLastError = true)]
        internal static extern uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr parameters);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DestroyMenu(IntPtr menu);

        internal static void SetExtendedStyle(IntPtr hwnd, int addFlags, int removeFlags)
        {
            int style = GetWindowLong(hwnd, GwlExStyle);
            int next = (style | addFlags) & ~removeFlags;
            if (next != style)
            {
                SetWindowLong(hwnd, GwlExStyle, next);
                SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0,
                    SwpNoMove | SwpNoSize | SwpNoZOrder | SwpNoActivate | SwpFrameChanged);
            }
        }

        internal static int GetDpi(IntPtr hwnd)
        {
            try
            {
                uint dpi = GetDpiForWindowNative(hwnd);
                if (dpi > 0) return (int)dpi;
            }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }

            IntPtr monitor = MonitorFromWindow(hwnd, MonitorDefaultToNearest);
            uint x;
            uint y;
            try
            {
                if (GetDpiForMonitorNative(monitor, 0, out x, out y) == 0 && x > 0) return (int)x;
            }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
            return 96;
        }

        internal static int GetDpiForMonitorHandle(IntPtr monitor)
        {
            uint x;
            uint y;
            try
            {
                if (GetDpiForMonitorNative(monitor, 0, out x, out y) == 0 && x > 0) return (int)x;
            }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
            return 96;
        }

        internal static bool IsClientAreaAnimationEnabled()
        {
            bool enabled = true;
            if (!SystemParametersInfo(SpiGetClientAreaAnimation, 0, ref enabled, 0)) return true;
            return enabled;
        }

        internal static List<MonitorArea> GetMonitors()
        {
            List<MonitorArea> result = new List<MonitorArea>();
            MonitorEnumProc callback = delegate(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data)
            {
                MonitorInfoEx info = new MonitorInfoEx();
                info.Size = (uint)Marshal.SizeOf(typeof(MonitorInfoEx));
                info.Device = new string('\0', 32);
                if (GetMonitorInfo(monitor, ref info))
                {
                    MonitorArea area = new MonitorArea();
                    area.Handle = monitor;
                    area.Device = (info.Device ?? String.Empty).TrimEnd('\0');
                    area.Work = info.Work;
                    area.IsPrimary = (info.Flags & 1) != 0;
                    result.Add(area);
                }
                return true;
            };
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
            return result;
        }

        internal static int GetWindowLongStyle(IntPtr hwnd)
        {
            return GetWindowLong(hwnd, GwlExStyle);
        }

        internal static void SetNonActivatingToolWindow(IntPtr hwnd)
        {
            SetExtendedStyle(hwnd, WsExToolWindow | WsExNoActivate, 0);
        }
    }
}
