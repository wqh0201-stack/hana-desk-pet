using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Windows
{
    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            // Same effect as the former HanaDesktopPet.exe.config overrides; a
            // single-file release has no sidecar config to carry them.
            AppContext.SetSwitch("Switch.System.Windows.DoNotScaleForDpiChanges", false);
            AppContext.SetSwitch("Switch.System.Windows.DoNotUsePresentationDpiCapabilityTier2OrGreater", false);
            if (args != null && args.Length == 1 && String.Equals(args[0], "--check-assets", StringComparison.Ordinal))
                return CheckAssets();
            if (args != null && args.Length != 0)
            {
                TryWriteError("Unknown command-line option.");
                return 2;
            }

            Mutex mutex = null;
            bool ownsMutex = false;
            try
            {
                mutex = new Mutex(false, @"Local\HanaDesktopPet");
                try { ownsMutex = mutex.WaitOne(0, false); }
                catch (AbandonedMutexException) { ownsMutex = true; }
                if (!ownsMutex) return 0;
                return RunApplication();
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Hana 桌宠无法启动。\n\n" + ex.Message,
                    "Hana 桌宠启动错误", MessageBoxButton.OK, MessageBoxImage.Error);
                return 1;
            }
            finally
            {
                if (ownsMutex && mutex != null)
                {
                    try { mutex.ReleaseMutex(); }
                    catch (ApplicationException) { }
                }
                if (mutex != null) mutex.Dispose();
            }
        }

        private static int CheckAssets()
        {
            try
            {
                PetArtworkCatalog catalog = new PetArtworkCatalog(
                    new EmbeddedPetAssetStore(Assembly.GetExecutingAssembly()));
                int decoded = 0;
                for (int roleIndex = 0; roleIndex < PetRole.BuiltIns.Count; roleIndex++)
                {
                    PetRole role = PetRole.BuiltIns[roleIndex];
                    ISet<string> poses = catalog.AvailablePoses(role.Id);
                    if (poses == null || poses.Count == 0 || !poses.Contains("idle"))
                        throw new InvalidDataException("The catalog has no usable idle pose for " + role.Id + ".");
                    foreach (string pose in poses)
                    {
                        PetArtwork artwork = catalog.GetArtwork(role.Id, pose);
                        if (artwork == null || artwork.Width <= 0 || artwork.Height <= 0)
                            throw new InvalidDataException("The catalog image could not be decoded: " + role.Id + "/" + pose + ".");
                        decoded++;
                    }
                }
                if (PetRole.BuiltIns.Count != 7 || decoded != 211)
                    throw new InvalidDataException("Expected 7 built-in roles and 211 PNG images; decoded " + decoded + ".");
                TryWriteOutput("Assets OK: 7 characters, 211 PNG images decoded.");
                return 0;
            }
            catch (Exception ex)
            {
                TryWriteError("Asset check failed: " + ex.GetType().Name + ": " + ex.Message);
                return 1;
            }
        }

        private static void TryWriteOutput(string message)
        {
            try { Console.Out.WriteLine(message); }
            catch { }
        }

        private static void TryWriteError(string message)
        {
            try { Console.Error.WriteLine(message); }
            catch { }
        }

        private static int RunApplication()
        {
            PetArtworkCatalog catalog;
            PetPreferences preferences = new PetPreferences();
            PetPreferencesData saved = preferences.Load();
            try
            {
                catalog = new PetArtworkCatalog(
                    new EmbeddedPetAssetStore(Assembly.GetExecutingAssembly()));
                for (int i = 0; i < PetRole.BuiltIns.Count; i++)
                {
                    PetRole role = PetRole.BuiltIns[i];
                    if (catalog.GetArtwork(role.Id, "idle") == null)
                        throw new InvalidDataException("The listed idle.png image is unavailable for " + role.Id + ".");
                }
                if (saved.Selection == null) saved.Selection = new PetSelection();
                if (catalog.GetArtwork(saved.Selection.CharacterId, "idle") == null)
                    throw new InvalidDataException("The selected character has no usable idle.png image.");
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Hana 桌宠无法启动，因为包内 CrossPet 资源没有可用的角色图片。\n\n" + ex.Message,
                    "Hana 桌宠资源错误", MessageBoxButton.OK, MessageBoxImage.Error);
                return 1;
            }

            PetStateStore store = new PetStateStore(saved.Selection);
            PetPoseReadbackStore poseReadback = new PetPoseReadbackStore();
            PetAnimator animator = new PetAnimator(delegate(string characterId)
            {
                return catalog.AvailablePoses(characterId);
            });
            PetWindow window = new PetWindow(store, poseReadback, animator, catalog, preferences, saved);
            LocalHttpServer server = new LocalHttpServer(store, poseReadback);
            server.StateChanged += window.OnServerStateChanged;
            server.ListenerStateChanged += window.OnListenerStateChanged;

            Application application = new Application();
            application.ShutdownMode = ShutdownMode.OnMainWindowClose;
            application.MainWindow = window;
            application.DispatcherUnhandledException += delegate(object sender, DispatcherUnhandledExceptionEventArgs args)
            {
                args.Handled = true;
                MessageBox.Show(
                    "Hana 桌宠遇到无法继续运行的错误。\n\n" + args.Exception.Message,
                    "Hana 桌宠运行错误", MessageBoxButton.OK, MessageBoxImage.Error);
                application.Shutdown(1);
            };

            int result = 0;
            try
            {
                try
                {
                    server.Start();
                }
                catch (Exception ex)
                {
                    window.OnListenerStateChanged("error: " + ex.Message);
                    MessageBox.Show(
                        "桌宠图片会继续显示，但 Hana 本机桥接监听器启动失败，控制台暂时无法更新状态或选择角色。\n\n" + ex.Message,
                        "Hana 桌宠桥接未启动", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
                result = application.Run(window);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Hana 桌宠启动失败。\n\n" + ex.Message,
                    "Hana 桌宠运行错误", MessageBoxButton.OK, MessageBoxImage.Error);
                result = 1;
            }
            finally
            {
                try { server.Dispose(); }
                catch { }
            }
            return result;
        }
    }
}
