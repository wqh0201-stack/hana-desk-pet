using System;
using System.Collections.Generic;
using System.Diagnostics;
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
                EmbeddedPetAssetStore store = new EmbeddedPetAssetStore(Assembly.GetExecutingAssembly());
                PetArtworkCatalog catalog = new PetArtworkCatalog(store);
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

                // The double-click basin is a shared prop outside the pose catalog. A single
                // unreadable file must not take the artwork path down, but the shipped build
                // has to carry it, so the self-check proves it decodes.
                System.Windows.Media.Imaging.BitmapSource basin = catalog.DecodeOptionalImage("shared/basin.png");
                if (basin == null || basin.PixelWidth <= 0 || basin.PixelHeight <= 0)
                    throw new InvalidDataException("The shared basin artwork is missing or cannot be decoded.");

                // The subtitle table is a native resource too. A table that fails to parse would
                // silently degrade to notices-only, so the check has to read it, not just look
                // for it in the index.
                PetSubtitleCatalog subtitles = PetSubtitleCatalog.Parse(store.ReadAllBytes("pet-lines.json"));
                string[] roles = subtitles.Roles;
                string[] states = subtitles.StateOrder;
                if (roles.Length != PetRole.BuiltIns.Count)
                    throw new InvalidDataException("Expected " + PetRole.BuiltIns.Count +
                        " subtitle roles; found " + roles.Length + ".");
                for (int roleIndex = 0; roleIndex < roles.Length; roleIndex++)
                {
                    if (!String.Equals(roles[roleIndex], PetRole.BuiltIns[roleIndex].Id, StringComparison.Ordinal))
                        throw new InvalidDataException("Subtitle role order does not match the built-in roles: " +
                            roles[roleIndex] + ".");
                }
                if (states.Length != 20)
                    throw new InvalidDataException("Expected 20 subtitle states; found " + states.Length + ".");
                int subtitleLines = 0;
                for (int roleIndex = 0; roleIndex < roles.Length; roleIndex++)
                {
                    for (int stateIndex = 0; stateIndex < states.Length; stateIndex++)
                    {
                        string[] wording = subtitles.Lines(roles[roleIndex], states[stateIndex]);
                        if (wording == null || wording.Length != 2)
                            throw new InvalidDataException("Subtitle table needs two lines for " +
                                roles[roleIndex] + "/" + states[stateIndex] + ".");
                        subtitleLines += wording.Length;
                    }
                }
                int expectedLines = roles.Length * states.Length * 2;
                if (subtitleLines != expectedLines)
                    throw new InvalidDataException("Expected " + expectedLines + " subtitle lines; parsed " +
                        subtitleLines + ".");

                TryWriteOutput("Assets OK: 7 characters, 211 PNG images decoded, 1 shared basin (" +
                    basin.PixelWidth + "x" + basin.PixelHeight + "), " + subtitleLines +
                    " subtitle lines parsed.");
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
            // The status subtitle table is a bundled native resource; a missing or malformed
            // table degrades to notices only instead of blocking the pet.
            try
            {
                PetSubtitleCatalog subtitleCatalog = PetSubtitleCatalog.Parse(
                    new EmbeddedPetAssetStore(Assembly.GetExecutingAssembly()).ReadAllBytes("pet-lines.json"));
                animator.AttachSubtitleCatalog(subtitleCatalog, 0x68616E6170657421UL);
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Hana Desktop Pet subtitle table unavailable: " + ex.GetType().Name);
            }
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
