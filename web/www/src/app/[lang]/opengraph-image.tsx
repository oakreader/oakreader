import { ImageResponse } from "next/og";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

// Branded social-share card rendered with next/og (Satori). One language-neutral
// English card for every locale — the brand wordmark is Latin and Satori has no
// CJK font, so a single image is both robust and conventional. Light theme to
// match the landing page, with a real product screenshot. Statically generated
// at build time; Node runtime is implied by the fs reads below.
export const alt = "Oak — The Context Library for you and your agent";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function Image() {
  const [bold, regular, icon, shot] = await Promise.all([
    readFile(join(process.cwd(), "assets/exposure-700.ttf")),
    readFile(join(process.cwd(), "assets/exposure-400.ttf")),
    readFile(join(process.cwd(), "public/icon.png")),
    readFile(join(process.cwd(), "assets/og-shot.png")),
  ]);
  const iconSrc = `data:image/png;base64,${icon.toString("base64")}`;
  const shotSrc = `data:image/png;base64,${shot.toString("base64")}`;

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          background: "linear-gradient(145deg, #ffffff 0%, #eef0f3 100%)",
          fontFamily: "Exposure",
          overflow: "hidden",
        }}
      >
        {/* Left: brand + headline */}
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            width: "520px",
            padding: "0 0 0 80px",
            flexShrink: 0,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: "18px", marginBottom: "40px" }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={iconSrc} width={56} height={56} style={{ borderRadius: 13 }} alt="" />
            <div style={{ display: "flex", fontSize: 32, fontWeight: 700, color: "#0a0a0a", letterSpacing: "-0.02em" }}>
              OakReader
            </div>
          </div>
          <div
            style={{
              display: "flex",
              fontSize: 56,
              fontWeight: 700,
              color: "#0a0a0a",
              lineHeight: 1.06,
              letterSpacing: "-0.03em",
            }}
          >
            The Context Library for you and your agent
          </div>
          <div
            style={{
              display: "flex",
              marginTop: "28px",
              fontSize: 25,
              fontWeight: 400,
              color: "#52525b",
              lineHeight: 1.35,
              maxWidth: "420px",
            }}
          >
            Everything you read in one place — searched and answered by AI.
          </div>
        </div>

        {/* Right: product screenshot, bleeding off the right edge */}
        <div style={{ display: "flex", flex: 1, alignItems: "center", justifyContent: "flex-start", marginLeft: "40px" }}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={shotSrc}
            width={820}
            height={535}
            style={{
              borderRadius: 16,
              border: "1px solid rgba(0,0,0,0.10)",
              boxShadow: "0 40px 80px -28px rgba(0,0,0,0.32)",
            }}
            alt=""
          />
        </div>
      </div>
    ),
    {
      ...size,
      fonts: [
        { name: "Exposure", data: bold, weight: 700, style: "normal" },
        { name: "Exposure", data: regular, weight: 400, style: "normal" },
      ],
    }
  );
}
