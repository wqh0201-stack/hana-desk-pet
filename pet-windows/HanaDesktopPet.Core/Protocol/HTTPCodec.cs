using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace HanaDesktopPet.Core
{
    public sealed class PetHTTPRequest
    {
        public string Method { get; private set; }
        public string Path { get; private set; }
        public IReadOnlyDictionary<string, string> Headers { get; private set; }
        public byte[] Body { get; private set; }

        public PetHTTPRequest(string method, string path, IReadOnlyDictionary<string, string> headers, byte[] body)
        {
            Method = method;
            Path = path;
            Headers = headers;
            Body = body;
        }
    }

    public sealed class PetHTTPResponse
    {
        public int StatusCode { get; private set; }
        public byte[] Body { get; private set; }
        public PetHTTPResponse(int statusCode, byte[] body) { StatusCode = statusCode; Body = body; }
    }

    public enum HTTPParseError
    {
        Malformed,
        HeaderTooLarge,
        BodyTooLarge,
        UnsupportedTransferEncoding,
        UnexpectedTrailingBytes
    }

    public sealed class PetHTTPParseException : Exception
    {
        public HTTPParseError Error { get; private set; }
        public int StatusCode
        {
            get { return Error == HTTPParseError.HeaderTooLarge || Error == HTTPParseError.BodyTooLarge ? 413 : 400; }
        }

        public PetHTTPParseException(HTTPParseError error) : base(error.ToString()) { Error = error; }
    }

    public static class PetHTTPCodec
    {
        public const int MaxHeaderBytes = 8 * 1024;
        public const int MaxBodyBytes = 16 * 1024;
        public const int MaxRequestBytes = MaxHeaderBytes + 4 + MaxBodyBytes;
        private static readonly byte[] HeaderDelimiter = new byte[] { 13, 10, 13, 10 };
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

        /// <summary>Returns null until the complete Content-Length-delimited request is available.</summary>
        public static PetHTTPRequest Parse(byte[] data)
        {
            int delimiterStart = FindDelimiter(data);
            if (delimiterStart < 0)
            {
                if (data.Length > MaxHeaderBytes) throw new PetHTTPParseException(HTTPParseError.HeaderTooLarge);
                return null;
            }
            if (delimiterStart > MaxHeaderBytes) throw new PetHTTPParseException(HTTPParseError.HeaderTooLarge);

            string headerText;
            try { headerText = StrictUtf8.GetString(data, 0, delimiterStart); }
            catch (DecoderFallbackException) { throw new PetHTTPParseException(HTTPParseError.Malformed); }

            string[] lines = headerText.Split(new string[] { "\r\n" }, StringSplitOptions.None);
            if (lines.Length == 0 || lines.Length > 65) throw new PetHTTPParseException(HTTPParseError.HeaderTooLarge);
            for (int i = 0; i < lines.Length; i++)
                if (lines[i].IndexOf('\r') >= 0 || lines[i].IndexOf('\n') >= 0)
                    throw new PetHTTPParseException(HTTPParseError.Malformed);

            string[] parts = lines[0].Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 3 || parts[0].Length == 0 || parts[1].Length == 0 || parts[1].Length > 1024 ||
                (parts[2] != "HTTP/1.0" && parts[2] != "HTTP/1.1") ||
                parts[0].Any(c => !IsTokenCharacter(c)) || parts[1].Any(char.IsControl) ||
                lines[0] != String.Join(" ", parts))
                throw new PetHTTPParseException(HTTPParseError.Malformed);

            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 1; i < lines.Length; i++)
            {
                string line = lines[i];
                if (line.Length == 0 || line[0] == ' ' || line[0] == '\t')
                    throw new PetHTTPParseException(HTTPParseError.Malformed);
                int colon = line.IndexOf(':');
                if (colon <= 0) throw new PetHTTPParseException(HTTPParseError.Malformed);
                string rawName = line.Substring(0, colon);
                if (rawName.Any(c => !IsTokenCharacter(c))) throw new PetHTTPParseException(HTTPParseError.Malformed);
                string name = rawName.ToLowerInvariant();
                string value = line.Substring(colon + 1).Trim(' ', '\t');
                if (headers.ContainsKey(name) || value.Any(c => Char.IsControl(c) && c != '\t'))
                    throw new PetHTTPParseException(HTTPParseError.Malformed);
                headers.Add(name, value);
            }

            if (headers.ContainsKey("transfer-encoding"))
                throw new PetHTTPParseException(HTTPParseError.UnsupportedTransferEncoding);

            int contentLength = 0;
            string rawLength;
            if (headers.TryGetValue("content-length", out rawLength))
            {
                if (rawLength.Length == 0 || rawLength.Any(c => c < '0' || c > '9') ||
                    !Int32.TryParse(rawLength, System.Globalization.NumberStyles.None,
                        System.Globalization.CultureInfo.InvariantCulture, out contentLength))
                    throw new PetHTTPParseException(HTTPParseError.Malformed);
            }
            if (contentLength > MaxBodyBytes) throw new PetHTTPParseException(HTTPParseError.BodyTooLarge);

            int bodyStart = delimiterStart + HeaderDelimiter.Length;
            int available = data.Length - bodyStart;
            if (available < contentLength) return null;
            if (available > contentLength) throw new PetHTTPParseException(HTTPParseError.UnexpectedTrailingBytes);

            var body = new byte[contentLength];
            if (contentLength > 0) Buffer.BlockCopy(data, bodyStart, body, 0, contentLength);
            return new PetHTTPRequest(parts[0], parts[1], headers, body);
        }

        public static byte[] Encode(PetHTTPResponse response)
        {
            string reason;
            switch (response.StatusCode)
            {
                case 200: reason = "OK"; break;
                case 400: reason = "Bad Request"; break;
                case 404: reason = "Not Found"; break;
                case 405: reason = "Method Not Allowed"; break;
                case 409: reason = "Conflict"; break;
                case 413: reason = "Payload Too Large"; break;
                case 415: reason = "Unsupported Media Type"; break;
                default: reason = "Internal Server Error"; break;
            }
            string header = "HTTP/1.1 " + response.StatusCode.ToString(CultureInfo.InvariantCulture) + " " + reason + "\r\n" +
                "Content-Type: application/json; charset=utf-8\r\n" +
                "Content-Length: " + response.Body.Length.ToString(CultureInfo.InvariantCulture) + "\r\n" +
                "Cache-Control: no-store\r\n" +
                "Connection: close\r\n\r\n";
            byte[] headerBytes = Encoding.ASCII.GetBytes(header);
            var output = new byte[headerBytes.Length + response.Body.Length];
            Buffer.BlockCopy(headerBytes, 0, output, 0, headerBytes.Length);
            Buffer.BlockCopy(response.Body, 0, output, headerBytes.Length, response.Body.Length);
            return output;
        }

        private static int FindDelimiter(byte[] data)
        {
            for (int i = 0; i <= data.Length - HeaderDelimiter.Length; i++)
            {
                if (data[i] == HeaderDelimiter[0] && data[i + 1] == HeaderDelimiter[1] &&
                    data[i + 2] == HeaderDelimiter[2] && data[i + 3] == HeaderDelimiter[3]) return i;
            }
            return -1;
        }

        private static bool IsTokenCharacter(char c)
        {
            return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
                (c >= 'a' && c <= 'z') || "!#$%&'*+-.^_`|~".IndexOf(c) >= 0;
        }
    }
}
