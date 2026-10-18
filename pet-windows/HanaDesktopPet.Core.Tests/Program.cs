using System;
using System.Threading;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Core.Tests
{
    internal static class Program
    {
        private static int Main(string[] arguments)
        {
            try
            {
                if (arguments.Length == 1 && arguments[0] == "--serve")
                {
                    // Synthetic test harness only: an OS-assigned loopback port, never 43127.
                    var store = new PetStateStore();
                    var readback = new PetPoseReadbackStore();
                    using (var server = new LocalHttpServer(store, readback, 0))
                    {
                        server.Start();
                        Console.WriteLine("{\"port\":" + server.BoundPort + "}");
                        Console.Out.Flush();
                        Console.ReadLine();
                    }
                    return 0;
                }
                ProtocolChecks.Run();
                TransportChecks.Run();
                AnimationChecks.Run();
                Console.WriteLine("PASS: Windows synthetic protocol and animation checks.");
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("FAIL: " + error.ToString());
                return 1;
            }
        }
    }
}
