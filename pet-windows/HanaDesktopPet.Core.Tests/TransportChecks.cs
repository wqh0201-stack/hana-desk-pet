using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Web.Script.Serialization;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Core.Tests
{
    public static class TransportChecks
    {
        public static void Run()
        {
            var store = new PetStateStore();
            var readback = new PetPoseReadbackStore();
            // Port 0 is deliberately used for all socket tests. No running pet or real
            // Hana session is contacted, and the production port remains untouched.
            using (var server = new LocalHttpServer(store, readback, 0))
            {
                server.Start();
                int port = server.BoundPort;
                Check(port > 0 && port != 43127, "An isolated ephemeral loopback port is assigned.");
                Response hello = Exchange(port, Request(port, "GET", "/v4/hello", null));
                Check(hello.Status == 200 && Convert.ToInt64(hello.Json["protocolVersion"]) == 4,
                    "A real loopback request completes the v4 handshake.");
                Response badHost = Exchange(port, "GET /v4/hello HTTP/1.1\r\nHost: example.invalid\r\n\r\n");
                Check(badHost.Status == 400, "An unapproved Host is rejected on the actual listener.");
                Response old = Exchange(port, Request(port, "GET", "/v2/hello", null));
                Check(old.Status == 404, "Old protocol routes stay unavailable.");
                var roles = new List<object>();
                foreach (PetRole role in PetRole.BuiltIns) roles.Add(new { id = role.Id, name = role.Name });
                var body = new JavaScriptSerializer().Serialize(new {
                    schemaVersion = 4, revision = 1, characters = roles,
                    activity = new {
                        sessionId = "synthetic-transport", title = "Synthetic socket check",
                        agentId = "synthetic-agent", agentName = "Synthetic agent",
                        status = "tool", toolName = "read_file", lastActivityAt = 123L
                    }
                });
                Response snapshot = Exchange(port, Request(port, "POST", "/v4/snapshot", body));
                Check(snapshot.Status == 200 && store.ViewState().Activity.ToolName == "read_file",
                    "A UTF-8 snapshot traverses the real transport and strict API.");
                string choose = "{\"schemaVersion\":4,\"characterId\":\"gpt\",\"expectedRevision\":0,\"updatedAt\":124}";
                Response selection = Exchange(port, Request(port, "POST", "/v4/selection", choose));
                Check(selection.Status == 200 && store.CurrentSelection().CharacterId == "gpt",
                    "Remote selection works without a different Hana client.");
                readback.Update("gpt", "picked-up", false, 125);
                Response state = Exchange(port, Request(port, "GET", "/v4/state", null));
                Check(state.Status == 200 && (string)state.Json["pose"] == "picked-up" && !(bool)state.Json["fallback"],
                    "The API exposes the last successful renderer readback through real HTTP.");
                Response chunked = Exchange(port, "POST /v4/snapshot HTTP/1.1\r\nHost: 127.0.0.1:" + port + "\r\nTransfer-Encoding: chunked\r\n\r\n");
                Check(chunked.Status == 400, "Unsupported transfer encodings are rejected on the listener.");
                using (var waiting = new TcpClient())
                {
                    waiting.Connect(IPAddress.Loopback, port);
                    waiting.ReceiveTimeout = 2000;
                    NetworkStream stream = waiting.GetStream();
                    byte[] partial = Encoding.ASCII.GetBytes("GET /v4/hello HTTP/1.1\r\n");
                    stream.Write(partial, 0, partial.Length);
                    server.Dispose();
                    try { Check(stream.ReadByte() == -1, "Dispose closes an incomplete connection."); }
                    catch (ObjectDisposedException) { }
                    catch (IOException error)
                    {
                        SocketException socketError = error.InnerException as SocketException;
                        if (socketError != null && socketError.SocketErrorCode == SocketError.TimedOut) throw;
                        // A peer reset also proves that shutdown closed the connection.
                    }
                }
            }
        }

        private static string Request(int port, string method, string route, string body)
        {
            string headers = method + " " + route + " HTTP/1.1\r\nHost: 127.0.0.1:" + port + "\r\nConnection: close\r\n";
            if (body != null) headers += "Content-Type: application/json\r\nContent-Length: " + Encoding.UTF8.GetByteCount(body) + "\r\n";
            return headers + "\r\n" + (body ?? "");
        }

        private static Response Exchange(int port, string request)
        {
            using (var client = new TcpClient())
            {
                client.SendTimeout = 3000;
                client.ReceiveTimeout = 3000;
                client.Connect(IPAddress.Loopback, port);
                using (NetworkStream stream = client.GetStream())
                {
                    byte[] bytes = Encoding.UTF8.GetBytes(request);
                    int split = bytes.Length / 2;
                    stream.Write(bytes, 0, split);
                    stream.Flush();
                    stream.Write(bytes, split, bytes.Length - split);
                    using (var output = new MemoryStream())
                    {
                        byte[] buffer = new byte[1024];
                        int count;
                        while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            output.Write(buffer, 0, count);
                            Check(output.Length <= 32768, "The response stays bounded.");
                        }
                        string text = Encoding.UTF8.GetString(output.ToArray());
                        int separator = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                        Check(separator >= 0, "A complete HTTP response is returned.");
                        string[] line = text.Substring(0, text.IndexOf("\r\n", StringComparison.Ordinal)).Split(' ');
                        return new Response(Int32.Parse(line[1]),
                            (IDictionary<string, object>)new JavaScriptSerializer().DeserializeObject(text.Substring(separator + 4)));
                    }
                }
            }
        }

        private sealed class Response
        {
            internal readonly int Status;
            internal readonly IDictionary<string, object> Json;
            internal Response(int status, IDictionary<string, object> json) { Status = status; Json = json; }
        }

        private static void Check(bool value, string message)
        {
            if (!value) throw new InvalidOperationException("Transport check failed: " + message);
        }
    }
}
