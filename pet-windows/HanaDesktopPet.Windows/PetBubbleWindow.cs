using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Windows
{
    /// <summary>
    /// The single bubble window. It is a separate, click-through, non-activating window so
    /// the pet window never grows, moves or changes its hit region.
    ///
    /// The surface is a large rounded rectangle (r18, 1 pt accent hairline, opaque white) with
    /// an independent small ellipse under its middle as the tail, plus a two-layer accent halo.
    /// The children are positioned from PetBubbleLayout's rects, so the Windows geometry is the
    /// same verified geometry macOS draws: the window includes the tail and the 8 pt halo
    /// margin, and the halo never paints below the body.
    /// </summary>
    internal sealed class PetBubbleWindow : Window
    {
        private const double FadeInSeconds = 0.18;
        private const double FadeOutSeconds = 0.15;

        private readonly Canvas _canvas;
        private readonly Border _surface;
        private readonly TextBlock _subtitle;
        private readonly TextBlock _title;
        private readonly TextBlock _status;
        private readonly StackPanel _lines;
        private readonly Ellipse _tail;
        private readonly Canvas _bodyHost;
        private readonly Canvas _tailHost;
        private IntPtr _hwnd;
        private IntPtr _petHwnd;
        private double _artworkTopInset;
        private string _shownId;
        private PetBubbleStyle _shownStyle;
        private int _fadeGeneration;

        internal PetBubbleWindow()
        {
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = true;
            Focusable = false;
            IsHitTestVisible = false;
            WindowStartupLocation = WindowStartupLocation.Manual;
            // The window size is set explicitly from PetBubbleLayout, so the painted geometry
            // and the window rectangle cannot drift apart.
            SizeToContent = SizeToContent.Manual;
            Left = 0;
            Top = 0;
            Opacity = 0;

            _subtitle = new TextBlock();
            _subtitle.FontSize = PetBubbleLayout.SubtitleFontSize;
            _subtitle.Foreground = new SolidColorBrush(Color.FromRgb(56, 56, 56));
            _subtitle.TextWrapping = TextWrapping.Wrap;
            _subtitle.TextAlignment = TextAlignment.Center;
            // Never CharacterEllipsis for a wrapped line: WPF reserves room for the ellipsis on
            // the last line, which would shorten an ordinary short line. The window is sized
            // from the measured text, so a line that fits is drawn in full.
            _subtitle.TextTrimming = TextTrimming.None;
            _subtitle.LineHeight = PetBubbleLayout.SubtitleLineHeight;
            _subtitle.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
            _subtitle.IsHitTestVisible = false;
            _subtitle.Visibility = Visibility.Collapsed;

            _title = new TextBlock();
            _title.FontSize = 12;
            _title.FontWeight = FontWeights.SemiBold;
            _title.Foreground = new SolidColorBrush(Color.FromRgb(26, 26, 26));
            _title.TextTrimming = TextTrimming.CharacterEllipsis;
            _title.TextWrapping = TextWrapping.NoWrap;
            _title.TextAlignment = TextAlignment.Center;
            _title.IsHitTestVisible = false;

            _status = new TextBlock();
            _status.FontSize = 11;
            _status.Foreground = new SolidColorBrush(Color.FromRgb(96, 96, 96));
            _status.TextTrimming = TextTrimming.CharacterEllipsis;
            _status.TextWrapping = TextWrapping.NoWrap;
            _status.TextAlignment = TextAlignment.Center;
            _status.Margin = new Thickness(0, PetBubbleLayout.LineSpacing, 0, 0);
            _status.IsHitTestVisible = false;

            _lines = new StackPanel();
            _lines.Orientation = Orientation.Vertical;
            _lines.Children.Add(_subtitle);
            _lines.Children.Add(_title);
            _lines.Children.Add(_status);

            _surface = new Border();
            _surface.CornerRadius = new CornerRadius(PetBubbleLayout.CornerRadius);
            _surface.Background = Brushes.White;
            _surface.BorderBrush = new SolidColorBrush(Color.FromRgb(0xB9, 0xB1, 0xA6));
            // The hairline is drawn inside the body rect, the same convention as macOS's
            // NSBezierPath inset, so the body occupies exactly PetBubbleLayout's body rect.
            _surface.BorderThickness = new Thickness(PetBubbleLayout.BorderWidth);
            _surface.Padding = new Thickness(PetBubbleLayout.PaddingX, PetBubbleLayout.PaddingY,
                PetBubbleLayout.PaddingX, PetBubbleLayout.PaddingY);
            _surface.Child = _lines;
            _surface.IsHitTestVisible = false;

            _tail = new Ellipse();
            _tail.Width = PetBubbleLayout.TailWidth;
            _tail.Height = PetBubbleLayout.TailHeight;
            _tail.Fill = Brushes.White;
            _tail.Stroke = _surface.BorderBrush;
            _tail.StrokeThickness = PetBubbleLayout.TailBorderWidth;
            _tail.IsHitTestVisible = false;

            // Each glow paints outside its element, so every glowing shape sits in its own
            // host that gets clipped in window coordinates.
            _bodyHost = new Canvas();
            _bodyHost.IsHitTestVisible = false;
            _bodyHost.Children.Add(_surface);
            _tailHost = new Canvas();
            _tailHost.IsHitTestVisible = false;
            _tailHost.Children.Add(_tail);

            _canvas = new Canvas();
            _canvas.IsHitTestVisible = false;
            _canvas.ClipToBounds = true;
            Content = _canvas;

            SourceInitialized += OnSourceInitialized;
        }

        private void OnSourceInitialized(object sender, EventArgs e)
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            if (_hwnd == IntPtr.Zero) return;
            NativeMethods.SetExtendedStyle(_hwnd,
                NativeMethods.WsExToolWindow | NativeMethods.WsExNoActivate | NativeMethods.WsExTransparent, 0);
        }

        internal void ShowBubble(PetBubbleContent bubble, string roleId, bool reduceMotion, IntPtr petHwnd)
        {
            if (bubble == null) return;
            _petHwnd = petHwnd;
            bool sameBubble = String.Equals(_shownId, bubble.Id, StringComparison.Ordinal) &&
                _shownStyle == bubble.Style && IsVisible;
            _shownId = bubble.Id;
            _shownStyle = bubble.Style;
            SolidColorBrush accent = BuildAccentBrush(PetBubbleTheme.Accent(roleId));
            ApplyAccent(accent);
            ApplyContent(bubble);
            SizeToBubble(bubble);
            if (!IsVisible)
            {
                _fadeGeneration++;
                Opacity = 0;
                Show();
            }
            UpdateLayout();
            Reposition();
            if (!sameBubble) FadeIn(reduceMotion);
        }

        private static SolidColorBrush BuildAccentBrush(PetBubbleAccent accent)
        {
            SolidColorBrush brush = new SolidColorBrush(Color.FromRgb(
                ToByte(accent.Red), ToByte(accent.Green), ToByte(accent.Blue)));
            brush.Freeze();
            return brush;
        }

        private void ApplyAccent(SolidColorBrush accent)
        {
            // The accent is border- and halo-only; the text colour never changes.
            _surface.BorderBrush = accent;
            _tail.Stroke = accent;
            _surface.Effect = BuildHalo(accent);
            _tail.Effect = BuildHalo(accent);
        }

        /// <summary>
        /// WPF offers one effect per element, so the reviewed three-pass halo is reproduced as
        /// a single accent glow whose blur radius and opacity are the combined reach and
        /// strength of the main and outer passes. It is applied to the body only; the shell
        /// below crops whatever it would smear toward the character.
        /// </summary>
        private static DropShadowEffect BuildHalo(SolidColorBrush accent)
        {
            DropShadowEffect effect = new DropShadowEffect();
            effect.Color = accent.Color;
            effect.BlurRadius = PetBubbleLayout.GlowMainBlur + PetBubbleLayout.GlowOuterSpread;
            effect.ShadowDepth = 0;
            effect.Direction = 270;
            effect.Opacity = PetBubbleLayout.GlowMainAlpha;
            effect.RenderingBias = RenderingBias.Quality;
            return effect;
        }

        private void ApplyContent(PetBubbleContent bubble)
        {
            bool subtitle = bubble.Style == PetBubbleStyle.Subtitle;
            _subtitle.Visibility = subtitle ? Visibility.Visible : Visibility.Collapsed;
            _title.Visibility = subtitle ? Visibility.Collapsed : Visibility.Visible;
            _status.Visibility = subtitle ? Visibility.Collapsed : Visibility.Visible;
            if (subtitle)
            {
                _subtitle.Text = bubble.Status;
            }
            else
            {
                _title.Text = bubble.Title;
                _status.Text = bubble.Status;
            }
        }

        /// <summary>
        /// Sizes the window from PetBubbleLayout and places the body and tail on their rects.
        ///
        /// The body halo is clipped to the body's own area plus the halo margin above and to
        /// the sides — <see cref="PetBubbleLayout.BodyGlowClip"/> — so it can never glow down
        /// onto the character's head. The tail gets its own small, equally bounded clip.
        /// </summary>
        private void SizeToBubble(PetBubbleContent bubble)
        {
            bool subtitle = bubble.Style == PetBubbleStyle.Subtitle;
            double contentWidth = PetBubbleLayout.MaxContentWidth;
            _subtitle.MaxWidth = contentWidth;
            _title.MaxWidth = contentWidth;
            _status.MaxWidth = contentWidth;
            _surface.MaxWidth = PetBubbleLayout.MaxWidth - PetBubbleLayout.GlowInset * 2;

            double width = PetBubbleLayout.Width(measuredTextWidth: MeasureTextWidth(subtitle));

            List<PetBubbleLayout.TextStyle> lines = new List<PetBubbleLayout.TextStyle>();
            if (subtitle)
            {
                lines.Add(PetBubbleLayout.TextStyle.Subtitle);
                // A wrapped line needs the reviewed two-line tier; sizing every subtitle to the
                // one-line tier clipped the bottom of the second line.
                if (WrapsToTwoLines(_subtitle, PetBubbleLayout.ContentWidthForWindow(width)))
                    lines.Add(PetBubbleLayout.TextStyle.Subtitle);
            }
            else
            {
                lines.Add(PetBubbleLayout.TextStyle.NoticeTitle);
                lines.Add(PetBubbleLayout.TextStyle.NoticeStatus);
            }
            double height = PetBubbleLayout.Height(lines.ToArray());
            Width = width;
            Height = height;
            _canvas.Width = width;
            _canvas.Height = height;

            PetBubbleRect body = PetBubbleLayout.BodyRect(width, height);
            PetBubbleRect tail = PetBubbleLayout.TailPathRect(width, height);
            PetBubbleRect bodyClip = PetBubbleLayout.BodyGlowClip(width, height);
            PetBubbleRect tailClip = PetBubbleLayout.TailGlowClip(width, height);

            // A fixed 18 pt radius makes a ~36 pt body a pill; cap it so a straight edge shows.
            _surface.CornerRadius = new CornerRadius(PetBubbleLayout.CornerRadiusFor(body.Height));

            Place(_surface, body);
            Place(_tail, tail);
            _tail.Stroke = _surface.BorderBrush;
            // Window-coordinate clips: the body halo stops at the body's bottom edge and the
            // tail halo stops at the tail tip, so neither ever glows onto the character.
            ClipHost(_bodyHost, width, height, bodyClip);
            ClipHost(_tailHost, width, height, tailClip);
            _canvas.Children.Clear();
            // Tail first so the body's hairline reads over the ellipse where they meet.
            _canvas.Children.Add(_tailHost);
            _canvas.Children.Add(_bodyHost);
        }

        /// <summary>Natural single-line width of the text this bubble will show.</summary>
        private double MeasureTextWidth(bool subtitle)
        {
            TextBlock probe = subtitle ? _subtitle : _title;
            probe.Measure(new Size(Double.PositiveInfinity, Double.PositiveInfinity));
            double widest = probe.DesiredSize.Width;
            if (!subtitle)
            {
                _status.Measure(new Size(Double.PositiveInfinity, Double.PositiveInfinity));
                widest = Math.Max(widest, _status.DesiredSize.Width);
            }
            return widest;
        }

        /// <summary>Whether the line needs a second row inside the given text column.</summary>
        private static bool WrapsToTwoLines(TextBlock probe, double columnWidth)
        {
            if (probe == null || String.IsNullOrEmpty(probe.Text) || columnWidth <= 0) return false;
            probe.Measure(new Size(columnWidth, Double.PositiveInfinity));
            return probe.DesiredSize.Height > PetBubbleLayout.SubtitleLineHeight + 0.5;
        }

        private static void ClipHost(Canvas host, double width, double height, PetBubbleRect clip)
        {
            host.Width = width;
            host.Height = height;
            host.Clip = clip.Width <= 0 || clip.Height <= 0
                ? new RectangleGeometry(new Rect(0, 0, 0, 0))
                : new RectangleGeometry(new Rect(clip.X, clip.Y, clip.Width, clip.Height));
        }

        private static void Place(FrameworkElement element, PetBubbleRect rect)
        {
            Canvas.SetLeft(element, rect.X);
            Canvas.SetTop(element, rect.Y);
            element.Width = rect.Width;
            element.Height = rect.Height;
        }

        internal void HideNotice(bool reduceMotion)
        {
            if (!IsVisible) return;
            _shownId = null;
            _fadeGeneration++;
            int generation = _fadeGeneration;
            if (reduceMotion)
            {
                BeginAnimation(OpacityProperty, null);
                Opacity = 0;
                Hide();
                return;
            }
            DoubleAnimation fade = new DoubleAnimation(0, TimeSpan.FromSeconds(FadeOutSeconds));
            fade.Completed += delegate
            {
                if (generation != _fadeGeneration) return;
                BeginAnimation(OpacityProperty, null);
                Opacity = 0;
                Hide();
            };
            BeginAnimation(OpacityProperty, fade);
        }

        internal void FollowPet(IntPtr petHwnd)
        {
            _petHwnd = petHwnd;
            if (IsVisible) Reposition();
        }

        private void FadeIn(bool reduceMotion)
        {
            _fadeGeneration++;
            BeginAnimation(OpacityProperty, null);
            if (reduceMotion)
            {
                Opacity = 1;
                return;
            }
            Opacity = 0;
            DoubleAnimation fade = new DoubleAnimation(1, TimeSpan.FromSeconds(FadeInSeconds));
            fade.EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut };
            BeginAnimation(OpacityProperty, fade);
        }

        /// <summary>
        /// How far below the pet window's top edge the drawn artwork starts, in DIP.
        /// The pet window keeps transparent room there for the sway, so the bubble must
        /// hang from the artwork line rather than the window edge.
        /// </summary>
        internal void SetPetArtworkTopInset(double inset)
        {
            if (Double.IsNaN(inset) || Double.IsInfinity(inset) || inset < 0) inset = 0;
            _artworkTopInset = inset;
        }

        private void Reposition()
        {
            if (_hwnd == IntPtr.Zero || _petHwnd == IntPtr.Zero) return;
            NativeMethods.Rect petRect;
            NativeMethods.Rect bubbleRect;
            if (!NativeMethods.GetWindowRect(_petHwnd, out petRect)) return;
            if (!NativeMethods.GetWindowRect(_hwnd, out bubbleRect)) return;
            IntPtr monitor = NativeMethods.MonitorFromWindow(_petHwnd, NativeMethods.MonitorDefaultToNearest);
            NativeMethods.MonitorArea area = FindMonitor(monitor);
            if (area == null) return;
            // Win32 hands back physical pixels. PetBubbleLayout is written in DIP so the
            // geometry stays comparable with the reference implementation and the tests.
            double scale = DpiScale();
            PetBubblePoint origin = PetBubbleLayout.Origin(
                new PetBubbleRect(petRect.Left / scale, petRect.Top / scale, petRect.Width / scale, petRect.Height / scale),
                bubbleRect.Width / scale,
                bubbleRect.Height / scale,
                new PetBubbleRect(area.Work.Left / scale, area.Work.Top / scale, area.Work.Width / scale, area.Work.Height / scale),
                _artworkTopInset);
            NativeMethods.SetWindowPos(_hwnd, NativeMethods.HwndTopmost,
                (int)Math.Round(origin.X * scale), (int)Math.Round(origin.Y * scale), 0, 0,
                NativeMethods.SwpNoSize | NativeMethods.SwpNoActivate);
        }

        private double DpiScale()
        {
            PresentationSource source = PresentationSource.FromVisual(this);
            if (source != null && source.CompositionTarget != null)
            {
                double scale = source.CompositionTarget.TransformToDevice.M11;
                if (scale > 0 && !Double.IsNaN(scale) && !Double.IsInfinity(scale)) return scale;
            }
            return 1.0;
        }

        private static byte ToByte(double value)
        {
            double clamped = value < 0 ? 0 : (value > 1 ? 1 : value);
            return (byte)Math.Round(clamped * 255.0);
        }

        private static NativeMethods.MonitorArea FindMonitor(IntPtr handle)
        {
            List<NativeMethods.MonitorArea> monitors = NativeMethods.GetMonitors();
            for (int i = 0; i < monitors.Count; i++)
                if (monitors[i].Handle == handle) return monitors[i];
            return null;
        }
    }
}
