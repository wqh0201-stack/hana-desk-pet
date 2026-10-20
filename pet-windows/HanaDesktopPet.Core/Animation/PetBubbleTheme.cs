using System;

namespace HanaDesktopPet.Core
{
    /// <summary>
    /// The bubble's accent colour per character.
    ///
    /// Source: upstream CrossPet v1.3.6 characters/&lt;role&gt;/character.json "accent", used
    /// only as a colour reference for this local prototype's border. No artwork, wording or
    /// other asset is copied. Both native ends keep the same small table;
    /// assets/crosspet/catalog.json is a material index and is deliberately not touched.
    /// </summary>
    internal struct PetBubbleAccent
    {
        internal readonly double Red;
        internal readonly double Green;
        internal readonly double Blue;

        internal PetBubbleAccent(double red, double green, double blue)
        {
            Red = red;
            Green = green;
            Blue = blue;
        }

        /// <summary>#rrggbb, so both native ends can be asserted against the same strings.</summary>
        internal string Hex
        {
            get { return "#" + Channel(Red) + Channel(Green) + Channel(Blue); }
        }

        private static string Channel(double value)
        {
            double clamped = value < 0 ? 0 : (value > 1 ? 1 : value);
            int octet = (int)Math.Round(clamped * 255.0);
            return octet.ToString("x2");
        }
    }

    internal static class PetBubbleTheme
    {
        /// <summary>Characters without their own upstream accent (the two outfit skins).</summary>
        internal static readonly PetBubbleAccent Fallback =
            new PetBubbleAccent(0xE0 / 255.0, 0xB4 / 255.0, 0x8A / 255.0);

        private static readonly string[] Roles = new[]
        {
            "claude", "gpt", "deepseek", "gemini", "glm", "deepseek-hoodie", "gpt-onesie"
        };

        private static PetBubbleAccent[] BuildAccents()
        {
            return new[]
            {
                new PetBubbleAccent(0xE8 / 255.0, 0xA3 / 255.0, 0x3D / 255.0), // claude
                new PetBubbleAccent(0x7A / 255.0, 0x8F / 255.0, 0xA8 / 255.0), // gpt
                new PetBubbleAccent(0x3B / 255.0, 0x5B / 255.0, 0xB5 / 255.0), // deepseek
                new PetBubbleAccent(0x7B / 255.0, 0x5C / 255.0, 0xD6 / 255.0), // gemini
                new PetBubbleAccent(0x4B / 255.0, 0x5A / 255.0, 0x8A / 255.0), // glm
                Fallback,                                                     // deepseek-hoodie
                Fallback,                                                     // gpt-onesie
            };
        }

        private static readonly PetBubbleAccent[] Accents = BuildAccents();

        internal static string[] KnownRoleIds { get { return (string[])Roles.Clone(); } }

        internal static PetBubbleAccent Accent(string roleId)
        {
            if (!String.IsNullOrEmpty(roleId))
            {
                for (int i = 0; i < Roles.Length; i++)
                    if (String.Equals(Roles[i], roleId, StringComparison.Ordinal)) return Accents[i];
            }
            return Fallback;
        }
    }
}
