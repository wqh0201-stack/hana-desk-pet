using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Windows
{
    internal sealed class PetWindow : Window
    {
        private const double DisplayHeight = 176.0;
        private const double HorizontalInset = 10.0;
        private const double MinimumHitCoverage = 1.0 / 255.0;
        private const int WmNcHitTest = 0x0084;
        private const int WmMouseActivate = 0x0021;
        private const int WmCaptureChanged = 0x0215;
        private const int WmCancelMode = 0x001F;
        private const int WmShowWindow = 0x0018;
        private const int WmSize = 0x0005;
        private const int WmDpiChanged = 0x02E0;
        private const int MenuRoleBase = 100;
        private const int MenuToggleLock = 201;
        private const int MenuDockTopLeft = 301;
        private const int MenuDockTopRight = 302;
        private const int MenuDockBottomLeft = 303;
        private const int MenuDockBottomRight = 304;
        private const int MenuQuit = 401;

        private static readonly Stopwatch MonotonicClock = Stopwatch.StartNew();

        private readonly PetStateStore _store;
        private readonly PetPoseReadbackStore _poseReadback;
        private readonly PetAnimator _animator;
        private readonly PetArtworkCatalog _catalog;
        private readonly PetPreferences _preferences;
        private readonly PetPreferencesData _preferenceData;
        private readonly Canvas _canvas;
        private readonly TextBlock _errorBadge;
        private readonly DispatcherTimer _stateTimer;
        private readonly DispatcherTimer _animationTimer;
        private readonly List<DisplayedLayer> _displayedLayers = new List<DisplayedLayer>();
        private readonly double _windowWidth;
        private readonly double _windowHeight;
        private readonly double _bottomInset;

        private HwndSource _source;
        private IntPtr _hwnd;
        private PetViewState _state;
        private PetRenderFrame _frame;
        private string _listenerState = "starting";
        private bool _positionLocked;
        private bool _isMenuOpen;
        private bool _pointerActive;
        private bool _pointerMoved;
        private bool _didDrag;
        private bool _ignoreCaptureLoss;
        private bool _isClosing;
        private bool _reduceMotion;
        private long _renderGeneration;
        private NativeMethods.Point _pointerOrigin;
        private NativeMethods.Rect _windowOrigin;

        private sealed class DisplayedLayer
        {
            public PetArtwork Artwork;
            public PetPoseLayer Layer;
            public double Left;
            public double Top;
            public double Width;
            public double Height;
        }

        public PetWindow(
            PetStateStore store,
            PetPoseReadbackStore poseReadback,
            PetAnimator animator,
            PetArtworkCatalog catalog,
            PetPreferences preferences,
            PetPreferencesData preferenceData)
        {
            _store = store;
            _poseReadback = poseReadback;
            _animator = animator;
            _catalog = catalog;
            _preferences = preferences;
            _preferenceData = preferenceData;
            _positionLocked = preferenceData.PositionLocked;
            _state = store.ViewState();

            double ratio = Math.Max(0.1, Math.Min(4.0, catalog.MaximumAspectRatio));
            double maximumWidth = DisplayHeight * ratio;
            double halfWidth = maximumWidth / 2.0;
            double radians = 4.0 * Math.PI / 180.0;
            double bottom = Math.Ceiling(1.055 * halfWidth * Math.Sin(radians) + 8.0);
            double top = Math.Ceiling(Math.Max(18.0, 1.055 * (DisplayHeight * Math.Cos(radians) + halfWidth * Math.Sin(radians)) - DisplayHeight + 8.0));
            double rotatedWidth = 1.055 * (maximumWidth * Math.Cos(radians) + DisplayHeight * Math.Sin(radians));
            _windowWidth = Math.Ceiling(rotatedWidth + 2.0 * HorizontalInset);
            _windowHeight = Math.Ceiling(DisplayHeight + bottom + top);
            _bottomInset = bottom;

            Title = "Hana Desk Pet";
            Width = _windowWidth;
            Height = _windowHeight;
            MinWidth = Width;
            MaxWidth = Width;
            MinHeight = Height;
            MaxHeight = Height;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = true;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = 0;
            Top = 0;
            FlowDirection = FlowDirection.LeftToRight;

            _canvas = new Canvas();
            _canvas.Width = _windowWidth;
            _canvas.Height = _windowHeight;
            _canvas.Background = Brushes.Transparent;
            _canvas.Focusable = false;
            _canvas.MouseLeftButtonDown += OnMouseLeftButtonDown;
            _canvas.MouseLeftButtonUp += OnMouseLeftButtonUp;
            _canvas.MouseMove += OnMouseMove;
            _canvas.MouseRightButtonUp += OnMouseRightButtonUp;
            _canvas.LostMouseCapture += OnLostMouseCapture;

            _errorBadge = new TextBlock();
            _errorBadge.Visibility = Visibility.Collapsed;
            _errorBadge.Foreground = Brushes.White;
            _errorBadge.Background = new SolidColorBrush(Color.FromArgb(224, 150, 24, 24));
            _errorBadge.Padding = new Thickness(6, 3, 6, 3);
            _errorBadge.FontSize = 12;
            _errorBadge.IsHitTestVisible = false;
            Canvas.SetLeft(_errorBadge, 8.0);
            Canvas.SetTop(_errorBadge, 8.0);
            _canvas.Children.Add(_errorBadge);
            Content = _canvas;

            _stateTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher);
            _stateTimer.Interval = TimeSpan.FromSeconds(1.0);
            _stateTimer.Tick += OnStateTimer;
            _stateTimer.Start();

            _animationTimer = new DispatcherTimer(DispatcherPriority.Render, Dispatcher);
            _animationTimer.Interval = TimeSpan.FromMilliseconds(20.0);
            _animationTimer.Tick += OnAnimationTimer;

            SourceInitialized += OnSourceInitialized;
            Loaded += OnLoaded;
            IsVisibleChanged += OnIsVisibleChanged;
            Closed += OnClosed;
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
            _reduceMotion = !NativeMethods.IsClientAreaAnimationEnabled();
            RefreshVisuals();
        }

        internal void OnServerStateChanged()
        {
            if (_isClosing) return;
            try { Dispatcher.BeginInvoke(new Action(RefreshFromStore), DispatcherPriority.DataBind); }
            catch (InvalidOperationException) { }
        }

        internal void OnListenerStateChanged(string state)
        {
            if (_isClosing) return;
            try
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    if (_isClosing) return;
                    _listenerState = String.IsNullOrWhiteSpace(state) ? "unknown" : state;
                    RefreshToolTip();
                }), DispatcherPriority.DataBind);
            }
            catch (InvalidOperationException) { }
        }

        private static double NowSeconds()
        {
            return MonotonicClock.Elapsed.TotalSeconds;
        }

        private void OnSourceInitialized(object sender, EventArgs e)
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            if (_hwnd == IntPtr.Zero) throw new InvalidOperationException("Windows did not create the pet window handle.");
            NativeMethods.SetNonActivatingToolWindow(_hwnd);
            _source = HwndSource.FromHwnd(_hwnd);
            if (_source == null) throw new InvalidOperationException("Windows could not attach the native pet-window handler.");
            _source.AddHook(WindowProcedure);
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            NativeMethods.SetNonActivatingToolWindow(_hwnd);
            RestoreWindowPosition();
            RefreshVisuals();
        }

        private void OnClosed(object sender, EventArgs e)
        {
            _isClosing = true;
            _stateTimer.Stop();
            _animationTimer.Stop();
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            if (_source != null)
            {
                _source.RemoveHook(WindowProcedure);
                _source = null;
            }
            if (_pointerActive) CancelPointerInteraction();
            SavePreferences();
        }

        private void OnIsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
        {
            if (!IsVisible && _pointerActive) CancelPointerInteraction();
            RefreshVisuals();
        }

        private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            try { Dispatcher.BeginInvoke(new Action(UpdateMotionSettings), DispatcherPriority.Background); }
            catch (InvalidOperationException) { }
        }

        private IntPtr WindowProcedure(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (message == WmMouseActivate)
            {
                handled = true;
                return new IntPtr(NativeMethods.MaNoActivate);
            }
            if (message == WmNcHitTest)
            {
                handled = true;
                return new IntPtr(NativeMethods.HtClient);
            }
            if ((message == WmCaptureChanged || message == WmCancelMode) && _pointerActive && !_ignoreCaptureLoss)
            {
                CancelPointerInteraction();
            }
            else if (message == WmDpiChanged)
            {
                try
                {
                    Dispatcher.BeginInvoke(new Action(delegate
                    {
                        if (!_isClosing)
                        {
                            ClampWindowToWorkArea();
                            SaveWindowPosition();
                            RefreshVisuals();
                        }
                    }), DispatcherPriority.Loaded);
                }
                catch (InvalidOperationException) { }
            }
            else if (message == WmShowWindow || message == WmSize)
            {
                try
                {
                    Dispatcher.BeginInvoke(new Action(delegate
                    {
                        if ((!IsVisible || NativeMethods.IsIconic(_hwnd)) && _pointerActive)
                            CancelPointerInteraction();
                        RefreshVisuals();
                    }), DispatcherPriority.Loaded);
                }
                catch (InvalidOperationException) { }
            }
            return IntPtr.Zero;
        }

        private void OnStateTimer(object sender, EventArgs e)
        {
            RefreshFromStore();
        }

        private void RefreshFromStore()
        {
            if (_isClosing) return;
            PetViewState next = _store.ViewState();
            if (SelectionChanged(_state == null ? null : _state.Selection, next.Selection))
            {
                _preferenceData.Selection = next.Selection;
                _preferences.Save(_preferenceData);
            }
            _state = next;
            RefreshVisuals();
        }

        private void RefreshVisuals()
        {
            if (_isClosing || _state == null) return;
            bool animationsEnabled = IsAnimationVisible();
            _frame = _animator.Update(_state, NowSeconds(), _reduceMotion, animationsEnabled);
            DrawCurrentFrame();
            ScheduleAnimationWake();
            RefreshToolTip();
        }

        private void DrawCurrentFrame()
        {
            _renderGeneration++;
            long generation = _renderGeneration;
            _canvas.Children.Clear();
            _displayedLayers.Clear();
            _errorBadge.Visibility = Visibility.Collapsed;
            _canvas.Children.Add(_errorBadge);
            Panel.SetZIndex(_errorBadge, Int32.MaxValue);

            string characterId = _frame == null ? null : _frame.CharacterId;
            if (String.IsNullOrEmpty(characterId) || _frame.Layers == null)
            {
                ShowArtworkError("桌宠姿态数据不可用。");
                return;
            }

            string error = null;
            for (int i = 0; i < _frame.Layers.Count; i++)
            {
                PetPoseLayer layer = _frame.Layers[i];
                try
                {
                    PetArtwork artwork = _catalog.GetArtwork(characterId, layer.Pose);
                    if (artwork == null) throw new InvalidOperationException("Pose is not listed in the bundled catalog.");
                    AddArtworkLayer(layer, artwork);
                }
                catch (Exception ex)
                {
                    error = "姿态图无法读取：" + characterId + "/" + (layer == null ? "unknown" : layer.Pose) + "。";
                    Debug.WriteLine("Hana Desktop Pet artwork load failed: " + ex.GetType().Name);
                    break;
                }
            }

            string readbackPose = _frame.Pose;
            bool readbackFallback = _frame.Fallback;
            if (error != null)
            {
                _displayedLayers.Clear();
                _canvas.Children.Clear();
                _canvas.Children.Add(_errorBadge);
                try
                {
                    PetArtwork idle = _catalog.GetArtwork(characterId, "idle");
                    if (idle == null) throw new InvalidOperationException("The listed idle pose is unavailable.");
                    PetPoseLayer idleLayer = new PetPoseLayer("idle", 1.0);
                    AddArtworkLayer(idleLayer, idle);
                    readbackPose = "idle";
                    readbackFallback = true;
                    ShowArtworkError(error);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine("Hana Desktop Pet idle artwork load failed: " + ex.GetType().Name);
                    _displayedLayers.Clear();
                    _canvas.Children.Clear();
                    _canvas.Children.Add(_errorBadge);
                    ShowArtworkError("桌宠图片不可用，请检查应用包内 CrossPet 资源。");
                    return;
                }
            }
            if (_displayedLayers.Count == 0)
            {
                ShowArtworkError("当前没有可显示的桌宠图片。");
                return;
            }
            bool selectedPoseVisible = false;
            for (int i = 0; i < _displayedLayers.Count; i++)
            {
                if (String.Equals(_displayedLayers[i].Layer.Pose, readbackPose, StringComparison.Ordinal) &&
                    _displayedLayers[i].Layer.Opacity > 0.001)
                {
                    selectedPoseVisible = true;
                    break;
                }
            }
            // At the first instant of a cross-fade, the destination can still have zero
            // visible opacity. Keep the last honest readback until this frame is actually drawn.
            if (!selectedPoseVisible) return;
            PetPoseReadbackStore readback = _poseReadback;
            string readbackCharacter = characterId;
            string actualPose = readbackPose;
            bool actualFallback = readbackFallback;
            Dispatcher.BeginInvoke(new Action(delegate
            {
                if (_isClosing || generation != _renderGeneration || !IsAnimationVisible()) return;
                readback.Update(readbackCharacter, actualPose, actualFallback);
            }), DispatcherPriority.ApplicationIdle);
        }

        private void AddArtworkLayer(PetPoseLayer layer, PetArtwork artwork)
        {
            double scale = Math.Min(DisplayHeight / artwork.Height, (_windowWidth - 2.0 * HorizontalInset) / artwork.Width);
            double width = artwork.Width * scale;
            double height = artwork.Height * scale;
            double left = (_windowWidth - width) / 2.0;
            double top = _windowHeight - _bottomInset - height;

            Image image = new Image();
            image.Source = artwork.Bitmap;
            image.Width = width;
            image.Height = height;
            image.Opacity = Clamp(layer.Opacity, 0.0, 1.0);
            image.Stretch = Stretch.Fill;
            image.IsHitTestVisible = false;
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
            Canvas.SetLeft(image, left);
            Canvas.SetTop(image, top);
            _canvas.Children.Add(image);

            DisplayedLayer displayed = new DisplayedLayer();
            displayed.Artwork = artwork;
            displayed.Layer = layer;
            displayed.Left = left;
            displayed.Top = top;
            displayed.Width = width;
            displayed.Height = height;
            _displayedLayers.Add(displayed);
        }

        private void ShowArtworkError(string message)
        {
            _errorBadge.Text = message;
            Canvas.SetLeft(_errorBadge, 8.0);
            Canvas.SetTop(_errorBadge, 8.0);
            _errorBadge.Visibility = Visibility.Visible;
        }

        private void ScheduleAnimationWake()
        {
            _animationTimer.Stop();
            if (!IsAnimationVisible() || _frame == null || !_frame.NextWakeAt.HasValue) return;
            double remaining = _frame.NextWakeAt.Value - NowSeconds();
            if (Double.IsNaN(remaining) || Double.IsInfinity(remaining)) return;
            remaining = Math.Max(0.001, Math.Min(60.0, remaining));
            _animationTimer.Interval = TimeSpan.FromSeconds(remaining);
            _animationTimer.Start();
        }

        private void OnAnimationTimer(object sender, EventArgs e)
        {
            _animationTimer.Stop();
            RefreshVisuals();
        }

        private bool IsAnimationVisible()
        {
            if (!IsVisible || _hwnd == IntPtr.Zero || _isMenuOpen) return false;
            return NativeMethods.IsWindowVisible(_hwnd) && !NativeMethods.IsIconic(_hwnd);
        }

        private void UpdateMotionSettings()
        {
            if (_isClosing) return;
            _reduceMotion = !NativeMethods.IsClientAreaAnimationEnabled();
            RefreshVisuals();
        }

        private bool HitTestPhysicalPoint(NativeMethods.Point point, NativeMethods.Rect windowRect)
        {
            if (windowRect.Width <= 0 || windowRect.Height <= 0) return false;
            int dpi = NativeMethods.GetDpi(_hwnd);
            if (dpi <= 0) dpi = 96;
            double localX = (point.X - windowRect.Left) * 96.0 / dpi;
            double localY = (point.Y - windowRect.Top) * 96.0 / dpi;
            if (localX < 0.0 || localY < 0.0 || localX >= _windowWidth || localY >= _windowHeight) return false;
            if (_errorBadge.Visibility == Visibility.Visible)
            {
                double badgeLeft = Canvas.GetLeft(_errorBadge);
                double badgeTop = Canvas.GetTop(_errorBadge);
                if (_errorBadge.ActualWidth > 0.0 && _errorBadge.ActualHeight > 0.0 &&
                    localX >= badgeLeft && localY >= badgeTop &&
                    localX < badgeLeft + _errorBadge.ActualWidth && localY < badgeTop + _errorBadge.ActualHeight)
                    return true;
            }
            if (_displayedLayers.Count == 0) return false;
            double remaining = 1.0;
            for (int i = 0; i < _displayedLayers.Count; i++)
            {
                DisplayedLayer displayed = _displayedLayers[i];
                if (displayed.Layer.Opacity <= 0.0 || displayed.Width <= 0.0 || displayed.Height <= 0.0 ||
                    localX < displayed.Left || localY < displayed.Top || localX >= displayed.Left + displayed.Width ||
                    localY >= displayed.Top + displayed.Height) continue;
                double alpha = SampleAlpha(displayed, localX, localY);
                double opacity = Clamp(displayed.Layer.Opacity, 0.0, 1.0);
                remaining *= 1.0 - opacity * alpha;
                if (1.0 - remaining >= MinimumHitCoverage) return true;
            }
            return 1.0 - remaining >= MinimumHitCoverage;
        }

        private static double SampleAlpha(DisplayedLayer layer, double x, double y)
        {
            double pixelX = (x - layer.Left) / layer.Width * layer.Artwork.Width - 0.5;
            double pixelY = (y - layer.Top) / layer.Height * layer.Artwork.Height - 0.5;
            pixelX = Clamp(pixelX, 0.0, layer.Artwork.Width - 1.0);
            pixelY = Clamp(pixelY, 0.0, layer.Artwork.Height - 1.0);
            int x0 = (int)Math.Floor(pixelX);
            int y0 = (int)Math.Floor(pixelY);
            int x1 = Math.Min(layer.Artwork.Width - 1, x0 + 1);
            int y1 = Math.Min(layer.Artwork.Height - 1, y0 + 1);
            double fx = pixelX - x0;
            double fy = pixelY - y0;
            double top = layer.Artwork.AlphaAt(x0, y0) * (1.0 - fx) + layer.Artwork.AlphaAt(x1, y0) * fx;
            double bottom = layer.Artwork.AlphaAt(x0, y1) * (1.0 - fx) + layer.Artwork.AlphaAt(x1, y1) * fx;
            return (top * (1.0 - fy) + bottom * fy) / 255.0;
        }

        private void OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (_pointerActive || _displayedLayers.Count == 0) return;
            NativeMethods.Point cursor;
            NativeMethods.Rect rect;
            if (!NativeMethods.GetCursorPos(out cursor) || !NativeMethods.GetWindowRect(_hwnd, out rect) || !HitTestPhysicalPoint(cursor, rect)) return;

            _pointerOrigin = cursor;
            _windowOrigin = rect;
            _pointerActive = true;
            _pointerMoved = false;
            _didDrag = false;
            _animator.BeginPointer(NowSeconds());
            RefreshVisuals();
            e.Handled = true;
            if (!Mouse.Capture(_canvas, CaptureMode.SubTree))
            {
                CancelPointerInteraction();
                return;
            }
        }

        private void OnMouseMove(object sender, MouseEventArgs e)
        {
            if (!_pointerActive || e.LeftButton != MouseButtonState.Pressed) return;
            NativeMethods.Point cursor;
            if (!NativeMethods.GetCursorPos(out cursor)) return;
            long dx = (long)cursor.X - _pointerOrigin.X;
            long dy = (long)cursor.Y - _pointerOrigin.Y;
            if (!_pointerMoved && dx * dx + dy * dy >= 16L) _pointerMoved = true;
            if (!_pointerMoved || _positionLocked) return;
            if (!_didDrag)
            {
                _didDrag = true;
                _animator.BeginDrag(NowSeconds());
            }
            MoveWindowTo(_windowOrigin.Left + (int)dx, _windowOrigin.Top + (int)dy);
            if (_didDrag && _animator.IsDragging) RefreshVisuals();
            e.Handled = true;
        }

        private void OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (!_pointerActive) return;
            NativeMethods.Point cursor;
            if (NativeMethods.GetCursorPos(out cursor))
            {
                long dx = (long)cursor.X - _pointerOrigin.X;
                long dy = (long)cursor.Y - _pointerOrigin.Y;
                if (!_pointerMoved && dx * dx + dy * dy >= 16L)
                {
                    _pointerMoved = true;
                    if (!_positionLocked)
                    {
                        _didDrag = true;
                        _animator.BeginDrag(NowSeconds());
                        MoveWindowTo(_windowOrigin.Left + (int)dx, _windowOrigin.Top + (int)dy);
                    }
                }
            }
            bool click = !_pointerMoved;
            bool dragged = _didDrag;
            _pointerActive = false;
            _ignoreCaptureLoss = true;
            try
            {
                if (Mouse.Captured == _canvas) Mouse.Capture(null);
            }
            finally { _ignoreCaptureLoss = false; }

            double now = NowSeconds();
            if (dragged)
            {
                _animator.EndDrag(now);
                ClampWindowToWorkArea();
                SaveWindowPosition();
            }
            else if (click)
            {
                _animator.Tap(now);
            }
            else
            {
                _animator.CancelInteraction(now);
            }
            e.Handled = true;
            RefreshVisuals();
        }

        private void OnLostMouseCapture(object sender, MouseEventArgs e)
        {
            if (_pointerActive && !_ignoreCaptureLoss) CancelPointerInteraction();
        }

        private void CancelPointerInteraction()
        {
            if (!_pointerActive) return;
            bool wasDragging = _didDrag;
            _pointerActive = false;
            _pointerMoved = false;
            _didDrag = false;
            _ignoreCaptureLoss = true;
            try
            {
                if (Mouse.Captured == _canvas) Mouse.Capture(null);
            }
            finally { _ignoreCaptureLoss = false; }
            _animator.CancelInteraction(NowSeconds());
            if (wasDragging)
            {
                ClampWindowToWorkArea();
                SaveWindowPosition();
            }
            RefreshVisuals();
        }

        private void OnMouseRightButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (_pointerActive) CancelPointerInteraction();
            NativeMethods.Point cursor;
            NativeMethods.Rect rect;
            if (!NativeMethods.GetCursorPos(out cursor) || !NativeMethods.GetWindowRect(_hwnd, out rect) || !HitTestPhysicalPoint(cursor, rect)) return;
            e.Handled = true;
            ShowNativeMenu(cursor);
        }

        private void ShowNativeMenu(NativeMethods.Point cursor)
        {
            if (_hwnd == IntPtr.Zero) return;
            _isMenuOpen = true;
            _animationTimer.Stop();
            RefreshVisuals();
            IntPtr root = NativeMethods.CreatePopupMenu();
            IntPtr dock = NativeMethods.CreatePopupMenu();
            if (root == IntPtr.Zero || dock == IntPtr.Zero)
            {
                if (root != IntPtr.Zero) NativeMethods.DestroyMenu(root);
                if (dock != IntPtr.Zero) NativeMethods.DestroyMenu(dock);
                _isMenuOpen = false;
                RefreshVisuals();
                return;
            }

            PetViewState state = _store.ViewState();
            for (int i = 0; i < PetRole.BuiltIns.Count; i++)
            {
                PetRole role = PetRole.BuiltIns[i];
                uint flags = NativeMethods.MfString;
                if (state.Selection != null && String.Equals(state.Selection.CharacterId, role.Id, StringComparison.Ordinal))
                    flags |= NativeMethods.MfChecked;
                NativeMethods.AppendMenu(root, flags, new IntPtr(MenuRoleBase + i), role.Name);
            }
            NativeMethods.AppendMenu(root, NativeMethods.MfSeparator, IntPtr.Zero, null);
            string lockLabel = _positionLocked ? "解锁位置" : "锁定位置";
            NativeMethods.AppendMenu(root, NativeMethods.MfString, new IntPtr(MenuToggleLock), lockLabel);
            NativeMethods.AppendMenu(dock, NativeMethods.MfString, new IntPtr(MenuDockTopLeft), "左上角");
            NativeMethods.AppendMenu(dock, NativeMethods.MfString, new IntPtr(MenuDockTopRight), "右上角");
            NativeMethods.AppendMenu(dock, NativeMethods.MfString, new IntPtr(MenuDockBottomLeft), "左下角");
            NativeMethods.AppendMenu(dock, NativeMethods.MfString, new IntPtr(MenuDockBottomRight), "右下角");
            NativeMethods.AppendMenu(root, NativeMethods.MfPopup, dock, "停靠并锁定");
            NativeMethods.AppendMenu(root, NativeMethods.MfSeparator, IntPtr.Zero, null);
            string listener = String.IsNullOrEmpty(_listenerState) ? "unknown" : _listenerState;
            NativeMethods.AppendMenu(root, NativeMethods.MfString | NativeMethods.MfGrayed, IntPtr.Zero, "本机桥接：" + listener);
            NativeMethods.AppendMenu(root, NativeMethods.MfSeparator, IntPtr.Zero, null);
            NativeMethods.AppendMenu(root, NativeMethods.MfString, new IntPtr(MenuQuit), "退出 Hana 桌宠");

            uint command = 0;
            try
            {
                command = NativeMethods.TrackPopupMenuEx(root,
                    NativeMethods.TpmRetcmd | NativeMethods.TpmNonotify | NativeMethods.TpmRightButton |
                    NativeMethods.TpmNoanimation,
                    cursor.X, cursor.Y, _hwnd, IntPtr.Zero);
            }
            finally
            {
                NativeMethods.DestroyMenu(root);
                _isMenuOpen = false;
            }
            HandleMenuCommand((int)command);
            RefreshVisuals();
        }

        private void HandleMenuCommand(int command)
        {
            if (command >= MenuRoleBase && command < MenuRoleBase + PetRole.BuiltIns.Count)
            {
                SelectRole(PetRole.BuiltIns[command - MenuRoleBase].Id);
                return;
            }
            if (command == MenuToggleLock)
            {
                _positionLocked = !_positionLocked;
                _preferenceData.PositionLocked = _positionLocked;
                SavePreferences();
            }
            else if (command == MenuDockTopLeft) DockToCorner(false, false);
            else if (command == MenuDockTopRight) DockToCorner(true, false);
            else if (command == MenuDockBottomLeft) DockToCorner(false, true);
            else if (command == MenuDockBottomRight) DockToCorner(true, true);
            else if (command == MenuQuit) Application.Current.Shutdown();
        }

        private void SelectRole(string roleId)
        {
            try
            {
                PetSelection selection = _store.SelectLocally(roleId);
                if (selection == null) return;
                _preferenceData.Selection = selection;
                _preferences.Save(_preferenceData);
                _state = _store.ViewState();
                RefreshVisuals();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "无法显示角色「" + roleId + "」的图片。\n\n" + ex.Message,
                    "Hana 桌宠", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void DockToCorner(bool right, bool bottom)
        {
            NativeMethods.Point cursor;
            if (!NativeMethods.GetCursorPos(out cursor)) return;
            IntPtr monitor = NativeMethods.MonitorFromPoint(cursor, NativeMethods.MonitorDefaultToNearest);
            NativeMethods.MonitorArea area = FindMonitor(monitor);
            NativeMethods.Rect rect;
            if (area == null || !NativeMethods.GetWindowRect(_hwnd, out rect)) return;
            int margin = (int)Math.Round(12.0 * NativeMethods.GetDpiForMonitorHandle(area.Handle) / 96.0);
            int x = right ? area.Work.Right - rect.Width - margin : area.Work.Left + margin;
            int y = bottom ? area.Work.Bottom - rect.Height - margin : area.Work.Top + margin;
            MoveWindowTo(x, y);
            _positionLocked = true;
            _preferenceData.PositionLocked = true;
            SaveWindowPosition();
            SavePreferences();
        }

        private void MoveWindowTo(int x, int y)
        {
            NativeMethods.SetWindowPos(_hwnd, NativeMethods.HwndTopmost, x, y, 0, 0,
                NativeMethods.SwpNoSize | NativeMethods.SwpNoActivate);
        }

        private void RestoreWindowPosition()
        {
            List<NativeMethods.MonitorArea> monitors = NativeMethods.GetMonitors();
            if (monitors.Count == 0) return;
            NativeMethods.MonitorArea target = null;
            PetWindowPosition saved = _preferenceData.WindowPosition;
            if (saved != null)
            {
                for (int i = 0; i < monitors.Count; i++)
                    if (String.Equals(monitors[i].Device, saved.MonitorDevice, StringComparison.OrdinalIgnoreCase))
                    {
                        target = monitors[i];
                        break;
                    }
            }
            if (target == null)
                for (int i = 0; i < monitors.Count; i++)
                    if (monitors[i].IsPrimary) { target = monitors[i]; break; }
            if (target == null) target = monitors[0];

            NativeMethods.Rect current;
            if (!NativeMethods.GetWindowRect(_hwnd, out current)) return;
            int maxX = Math.Max(target.Work.Left, target.Work.Right - current.Width);
            int maxY = Math.Max(target.Work.Top, target.Work.Bottom - current.Height);
            double xRatio = saved == null ? 1.0 : saved.XRatio;
            double yRatio = saved == null ? 1.0 : saved.YRatio;
            int x;
            int y;
            if (saved == null)
            {
                int margin = (int)Math.Round(12.0 * NativeMethods.GetDpiForMonitorHandle(target.Handle) / 96.0);
                x = Math.Max(target.Work.Left, maxX - margin);
                y = Math.Max(target.Work.Top, maxY - margin);
            }
            else
            {
                x = target.Work.Left + (int)Math.Round((maxX - target.Work.Left) * Clamp(xRatio, 0.0, 1.0));
                y = target.Work.Top + (int)Math.Round((maxY - target.Work.Top) * Clamp(yRatio, 0.0, 1.0));
            }
            MoveWindowTo(x, y);
            SaveWindowPosition();
        }

        private void ClampWindowToWorkArea()
        {
            NativeMethods.Rect rect;
            if (!NativeMethods.GetWindowRect(_hwnd, out rect)) return;
            NativeMethods.MonitorArea area = FindMonitor(NativeMethods.MonitorFromWindow(_hwnd, NativeMethods.MonitorDefaultToNearest));
            if (area == null) return;
            int maxX = Math.Max(area.Work.Left, area.Work.Right - rect.Width);
            int maxY = Math.Max(area.Work.Top, area.Work.Bottom - rect.Height);
            int x = Math.Max(area.Work.Left, Math.Min(maxX, rect.Left));
            int y = Math.Max(area.Work.Top, Math.Min(maxY, rect.Top));
            if (x != rect.Left || y != rect.Top) MoveWindowTo(x, y);
        }

        private void SaveWindowPosition()
        {
            if (_hwnd == IntPtr.Zero) return;
            NativeMethods.Rect rect;
            if (!NativeMethods.GetWindowRect(_hwnd, out rect)) return;
            NativeMethods.MonitorArea area = FindMonitor(NativeMethods.MonitorFromWindow(_hwnd, NativeMethods.MonitorDefaultToNearest));
            if (area == null) return;
            int maxX = Math.Max(area.Work.Left, area.Work.Right - rect.Width);
            int maxY = Math.Max(area.Work.Top, area.Work.Bottom - rect.Height);
            double xDenominator = maxX - area.Work.Left;
            double yDenominator = maxY - area.Work.Top;
            double xRatio = xDenominator <= 0 ? 0.0 : (double)(rect.Left - area.Work.Left) / xDenominator;
            double yRatio = yDenominator <= 0 ? 0.0 : (double)(rect.Top - area.Work.Top) / yDenominator;
            _preferenceData.WindowPosition = new PetWindowPosition
            {
                MonitorDevice = area.Device,
                XRatio = Clamp(xRatio, 0.0, 1.0),
                YRatio = Clamp(yRatio, 0.0, 1.0)
            };
            SavePreferences();
        }

        private void SavePreferences()
        {
            _preferenceData.PositionLocked = _positionLocked;
            if (_state != null && _state.Selection != null) _preferenceData.Selection = _state.Selection;
            _preferences.Save(_preferenceData);
        }

        private NativeMethods.MonitorArea FindMonitor(IntPtr handle)
        {
            List<NativeMethods.MonitorArea> monitors = NativeMethods.GetMonitors();
            for (int i = 0; i < monitors.Count; i++)
                if (monitors[i].Handle == handle) return monitors[i];
            return null;
        }

        private void RefreshToolTip()
        {
            if (_state == null) return;
            string roleName = "桌宠";
            for (int i = 0; i < _state.Roles.Count; i++)
                if (String.Equals(_state.Roles[i].Id, _state.Selection.CharacterId, StringComparison.Ordinal))
                {
                    roleName = _state.Roles[i].Name;
                    break;
                }
            string status = Convert.ToString(_state.DisplayStatus);
            if (String.IsNullOrEmpty(status)) status = "未知";
            string connection = _state.AppConnected ? "已连接" : "未连接";
            ToolTip = roleName + " · " + status + " · Hana " + connection + " · 本机桥接 " + _listenerState;
            _canvas.ToolTip = ToolTip;
        }

        private static bool SelectionChanged(PetSelection left, PetSelection right)
        {
            if (left == null || right == null) return !Object.ReferenceEquals(left, right);
            return !String.Equals(left.CharacterId, right.CharacterId, StringComparison.Ordinal) ||
                left.Revision != right.Revision || left.UpdatedAt != right.UpdatedAt;
        }

        private static double Clamp(double value, double minimum, double maximum)
        {
            if (Double.IsNaN(value)) return minimum;
            if (Double.IsInfinity(value)) return value > 0.0 ? maximum : minimum;
            if (value < minimum) return minimum;
            if (value > maximum) return maximum;
            return value;
        }
    }
}
