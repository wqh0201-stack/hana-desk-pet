using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Windows
{
    /// <summary>
    /// Debug window for one character's basin geometry: width, x offset and y offset, with
    /// live preview and a save/reset pair.
    /// </summary>
    /// <remarks>
    /// Nothing is persisted until 保存; 重置 drops the saved override so the built-in
    /// <c>PetBasinStack.ConfigFor</c> row applies again. The readouts are the numbers to copy
    /// into that table once a character looks right.
    /// </remarks>
    internal sealed class PetBasinDebugWindow : Window
    {
        private readonly Slider _widthSlider = new Slider();
        private readonly Slider _xSlider = new Slider();
        private readonly Slider _ySlider = new Slider();
        private readonly TextBlock _role = new TextBlock();
        private readonly TextBlock _widthValue = new TextBlock();
        private readonly TextBlock _xValue = new TextBlock();
        private readonly TextBlock _yValue = new TextBlock();
        private readonly Func<string, PetBasinConfig> _resolve;
        private readonly Action<string, PetBasinConfig> _onPreview;
        private readonly Action<string, PetBasinConfig> _onSave;
        private readonly Action<string> _onReset;
        private string _roleId;
        private PetBasinConfig _config;
        private bool _ready;

        public PetBasinDebugWindow(
            string roleId,
            PetBasinConfig config,
            Func<string, PetBasinConfig> resolve,
            Action<string, PetBasinConfig> onPreview,
            Action<string, PetBasinConfig> onSave,
            Action<string> onReset)
        {
            _roleId = roleId;
            _resolve = resolve;
            _onPreview = onPreview;
            _onSave = onSave;
            _onReset = onReset;

            Title = "铁盆调试";
            Width = 340.0;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ShowInTaskbar = false;
            Topmost = true;
            Background = Brushes.White;

            StackPanel panel = new StackPanel();
            panel.Margin = new Thickness(16.0);
            _role.FontSize = 12.0;
            _role.FontWeight = FontWeights.Medium;
            panel.Children.Add(_role);

            AddRow(panel, "宽度", _widthSlider, _widthValue,
                PetBasinStack.WidthMinimum, PetBasinStack.WidthMaximum);
            AddRow(panel, "X 偏移", _xSlider, _xValue,
                PetBasinStack.XOffsetMinimum, PetBasinStack.XOffsetMaximum);
            AddRow(panel, "Y 偏移（立绘顶边向下）", _ySlider, _yValue,
                PetBasinStack.YOffsetMinimum, PetBasinStack.YOffsetMaximum);

            StackPanel buttons = new StackPanel();
            buttons.Orientation = Orientation.Horizontal;
            buttons.Margin = new Thickness(0.0, 12.0, 0.0, 0.0);
            Button save = new Button();
            save.Content = "保存";
            save.Width = 72.0;
            save.Margin = new Thickness(0.0, 0.0, 8.0, 0.0);
            save.Click += delegate { if (_onSave != null) _onSave(_roleId, _config); };
            buttons.Children.Add(save);
            Button reset = new Button();
            reset.Content = "重置";
            reset.Width = 72.0;
            reset.Click += delegate
            {
                if (_onReset != null) _onReset(_roleId);
                if (_resolve != null) Apply(_resolve(_roleId));
            };
            buttons.Children.Add(reset);
            panel.Children.Add(buttons);

            Content = panel;
            _ready = true;
            Apply(config == null ? PetBasinConfig.Fallback : config);
        }

        public void Reload(string roleId, PetBasinConfig config)
        {
            _roleId = roleId;
            Apply(config == null ? PetBasinConfig.Fallback : config);
        }

        private void AddRow(StackPanel panel, string title, Slider slider, TextBlock value, double minimum, double maximum)
        {
            Grid header = new Grid();
            header.Margin = new Thickness(0.0, 8.0, 0.0, 2.0);
            TextBlock label = new TextBlock();
            label.Text = title;
            label.FontSize = 12.0;
            label.Foreground = Brushes.DimGray;
            header.Children.Add(label);
            value.FontSize = 12.0;
            value.Foreground = Brushes.DimGray;
            value.HorizontalAlignment = HorizontalAlignment.Right;
            header.Children.Add(value);
            panel.Children.Add(header);

            slider.Minimum = minimum;
            slider.Maximum = maximum;
            slider.IsSnapToTickEnabled = false;
            slider.ValueChanged += OnSliderChanged;
            panel.Children.Add(slider);
        }

        private void Apply(PetBasinConfig config)
        {
            PetBasinConfig clamped = (config == null ? PetBasinConfig.Fallback : config).Clamped();
            _config = clamped;
            _role.Text = "角色：" + (_roleId == null ? "未知" : _roleId);
            _widthSlider.Value = clamped.Width;
            _xSlider.Value = clamped.XOffset;
            _ySlider.Value = clamped.YOffset;
            UpdateReadouts();
        }

        private void UpdateReadouts()
        {
            _widthValue.Text = String.Format("{0:0.0} pt", _config.Width);
            _xValue.Text = String.Format("{0:0.0} pt", _config.XOffset);
            _yValue.Text = String.Format("{0:0.0} pt", _config.YOffset);
        }

        private void OnSliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (!_ready) return;
            _config = new PetBasinConfig(_widthSlider.Value, _xSlider.Value, _ySlider.Value).Clamped();
            // Keep the sliders inside the clamp so the readout never lies.
            _widthSlider.Value = _config.Width;
            _xSlider.Value = _config.XOffset;
            _ySlider.Value = _config.YOffset;
            UpdateReadouts();
            if (_onPreview != null) _onPreview(_roleId, _config);
        }
    }
}
