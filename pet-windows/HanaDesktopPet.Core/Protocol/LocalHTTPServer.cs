using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace HanaDesktopPet.Core
{
    /// <summary>A bounded HTTP/1.x server bound only to the IPv4 loopback interface.</summary>
    public sealed class LocalHttpServer : IDisposable
    {
        private const int MaxConcurrentConnections = 16;
        private static readonly TimeSpan ConnectionDeadline = TimeSpan.FromSeconds(8);
        private readonly PetAPI api;
        private readonly TcpListener listener;
        private readonly SemaphoreSlim connectionSlots = new SemaphoreSlim(MaxConcurrentConnections, MaxConcurrentConnections);
        private readonly ConcurrentDictionary<int, TcpClient> clients = new ConcurrentDictionary<int, TcpClient>();
        private readonly ConcurrentDictionary<int, Task> clientTasks = new ConcurrentDictionary<int, Task>();
        private readonly CancellationTokenSource shutdown = new CancellationTokenSource();
        private readonly object gate = new object();
        private Task acceptTask;
        private int nextClientId;
        private int resourcesDisposed;
        private bool started;
        private bool disposed;

        public event Action StateChanged;
        public event Action<string> ListenerStateChanged;
        public int BoundPort { get; private set; }

        public LocalHttpServer(PetStateStore store, PetPoseReadbackStore readback, int port = 43127)
        {
            if (port < 0 || port > 65535) throw new ArgumentOutOfRangeException("port");
            listener = new TcpListener(IPAddress.Loopback, port);
            api = new PetAPI(store, readback);
            BoundPort = port;
        }

        public void Start()
        {
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("LocalHttpServer");
                if (started) return;
                started = true;
            }
            RaiseListenerState("starting");
            try
            {
                lock (gate)
                {
                    if (disposed) throw new ObjectDisposedException("LocalHttpServer");
                    listener.Start(MaxConcurrentConnections);
                    BoundPort = ((IPEndPoint)listener.LocalEndpoint).Port;
                    acceptTask = AcceptLoopAsync(shutdown.Token);
                }
                RaiseListenerState("listening");
            }
            catch
            {
                lock (gate)
                {
                    started = false;
                }
                if (!disposed) RaiseListenerState("error");
                throw;
            }
        }

        public void Dispose()
        {
            Task currentAcceptTask;
            lock (gate)
            {
                if (disposed) return;
                disposed = true;
                shutdown.Cancel();
                try { listener.Stop(); } catch (SocketException) { }
                foreach (TcpClient client in clients.Values)
                {
                    try { client.Close(); } catch (SocketException) { }
                }
                currentAcceptTask = acceptTask;
            }
            RaiseListenerState("stopped");
            if (currentAcceptTask == null)
            {
                DisposeResources();
                return;
            }
            currentAcceptTask.ContinueWith(delegate(Task ignoredAcceptTask)
            {
                Task[] remaining = clientTasks.Values.ToArray();
                Task.WhenAll(remaining).ContinueWith(delegate(Task ignoredClientTasks) { DisposeResources(); });
            });
        }

        private async Task AcceptLoopAsync(CancellationToken cancellationToken)
        {
            try
            {
                while (!cancellationToken.IsCancellationRequested)
                {
                    await connectionSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
                    TcpClient client = null;
                    try
                    {
                        client = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
                        if (cancellationToken.IsCancellationRequested)
                        {
                            client.Close();
                            connectionSlots.Release();
                            break;
                        }
                        client.NoDelay = true;
                        int id = Interlocked.Increment(ref nextClientId);
                        clients.TryAdd(id, client);
                        Task task = HandleClientAsync(id, client, cancellationToken);
                        clientTasks[id] = task;
                        task.ContinueWith(delegate(Task ignoredTask)
                        {
                            Task ignored;
                            clientTasks.TryRemove(id, out ignored);
                        });
                        client = null;
                    }
                    catch
                    {
                        if (client != null) client.Close();
                        SafeReleaseSlot();
                        throw;
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (ObjectDisposedException) { if (!cancellationToken.IsCancellationRequested) RaiseListenerState("error"); }
            catch (SocketException) { if (!cancellationToken.IsCancellationRequested) RaiseListenerState("error"); }
            catch { if (!cancellationToken.IsCancellationRequested) RaiseListenerState("error"); }
        }

        private async Task HandleClientAsync(int id, TcpClient client, CancellationToken serverToken)
        {
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(serverToken))
            {
                deadline.CancelAfter(ConnectionDeadline);
                using (deadline.Token.Register(delegate
                {
                    try { client.Close(); } catch (SocketException) { }
                }))
                {
                    try
                    {
                        using (NetworkStream stream = client.GetStream())
                        using (var received = new System.IO.MemoryStream())
                        {
                            byte[] buffer = new byte[4096];
                            while (received.Length <= PetHTTPCodec.MaxRequestBytes)
                            {
                                int remaining = PetHTTPCodec.MaxRequestBytes + 1 - (int)received.Length;
                                int amount = await stream.ReadAsync(buffer, 0, Math.Min(buffer.Length, remaining), deadline.Token).ConfigureAwait(false);
                                if (amount == 0)
                                {
                                    await WriteResponseAsync(stream, InvalidRequest(400), deadline.Token).ConfigureAwait(false);
                                    return;
                                }
                                received.Write(buffer, 0, amount);

                                PetHTTPRequest request = null;
                                int parseStatus = 0;
                                try { request = PetHTTPCodec.Parse(received.ToArray()); }
                                catch (PetHTTPParseException exception) { parseStatus = exception.StatusCode; }
                                if (parseStatus != 0)
                                {
                                    await WriteResponseAsync(stream, InvalidRequest(parseStatus), deadline.Token).ConfigureAwait(false);
                                    return;
                                }
                                if (request == null) continue;
                                if (!IsAllowedHost(request))
                                {
                                    await WriteResponseAsync(stream, InvalidRequest(400), deadline.Token).ConfigureAwait(false);
                                    return;
                                }

                                PetHTTPResponse response = api.Handle(request);
                                if (response.StatusCode == 200 && request.Method == "POST" &&
                                    (request.Path == "/v3/snapshot" || request.Path == "/v3/selection"))
                                    RaiseStateChanged();
                                await WriteResponseAsync(stream, response, deadline.Token).ConfigureAwait(false);
                                return;
                            }
                            await WriteResponseAsync(stream, InvalidRequest(413), deadline.Token).ConfigureAwait(false);
                        }
                    }
                    catch (OperationCanceledException) { }
                    catch (System.IO.IOException) { }
                    catch (SocketException) { }
                    catch { }
                    finally
                    {
                        TcpClient ignored;
                        clients.TryRemove(id, out ignored);
                        try { client.Close(); } catch (SocketException) { }
                        SafeReleaseSlot();
                    }
                }
            }
        }

        private bool IsAllowedHost(PetHTTPRequest request)
        {
            string host;
            return request.Headers.TryGetValue("host", out host) &&
                (String.Equals(host, "127.0.0.1:" + BoundPort.ToString(CultureInfo.InvariantCulture), StringComparison.OrdinalIgnoreCase) ||
                 String.Equals(host, "127.0.0.1", StringComparison.OrdinalIgnoreCase));
        }

        private static async Task WriteResponseAsync(NetworkStream stream, PetHTTPResponse response, CancellationToken cancellationToken)
        {
            byte[] bytes = PetHTTPCodec.Encode(response);
            await stream.WriteAsync(bytes, 0, bytes.Length, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }

        private static PetHTTPResponse InvalidRequest(int statusCode)
        {
            var serializer = new JavaScriptSerializer();
            return new PetHTTPResponse(statusCode, Encoding.UTF8.GetBytes(serializer.Serialize(new { error = "invalid_request" })));
        }

        private void RaiseListenerState(string value)
        {
            try
            {
                Action<string> handler = ListenerStateChanged;
                if (handler != null) handler(value);
            }
            catch { }
        }

        private void RaiseStateChanged()
        {
            try
            {
                Action handler = StateChanged;
                if (handler != null) handler();
            }
            catch { }
        }

        private void SafeReleaseSlot()
        {
            try { connectionSlots.Release(); } catch (ObjectDisposedException) { }
        }

        private void DisposeResources()
        {
            if (Interlocked.Exchange(ref resourcesDisposed, 1) != 0) return;
            try { connectionSlots.Dispose(); } catch (ObjectDisposedException) { }
            shutdown.Dispose();
        }
    }
}
