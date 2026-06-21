import { ImageResponse } from "next/og";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

// Branded social-share card rendered with next/og (Satori). One language-neutral
// English card for every locale — the brand wordmark is Latin and Satori has no
// CJK font, so a single image is both robust and conventional. Light theme to
// match the landing page, with a real product screenshot. Statically generated
// at build time; Node runtime is implied by the fs reads below.
export const alt = "Oak — The Knowledge Library for you and your agent";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function Image() {
  const [regular, icon, shot] = await Promise.all([
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
          background: "linear-gradient(150deg, #ffffff 0%, #f1f2f5 100%)",
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
            width: "420px",
            padding: "0 0 0 84px",
            flexShrink: 0,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: "14px", marginBottom: "56px" }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={iconSrc} width={42} height={42} style={{ borderRadius: 10 }} alt="" />
            <div style={{ display: "flex", fontSize: 30, fontWeight: 400, color: "#18181b", letterSpacing: "-0.01em" }}>
              OakReader
            </div>
          </div>
          <div
            style={{
              display: "flex",
              fontSize: 40,
              fontWeight: 400,
              color: "#0a0a0a",
              lineHeight: 1.18,
              letterSpacing: "-0.02em",
              maxWidth: "380px",
            }}
          >
            The Knowledge Library for you and your agent
          </div>
          <div
            style={{
              display: "flex",
              marginTop: "30px",
              fontSize: 20,
              fontWeight: 400,
              color: "#71717a",
              lineHeight: 1.5,
              maxWidth: "340px",
            }}
          >
            Everything you read in one place — searched and answered by AI.
          </div>
        </div>

        {/* Right: product screenshot, fully visible with margin on every side */}
        <div style={{ display: "flex", flex: 1, alignItems: "center", justifyContent: "center", paddingRight: "72px" }}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={shotSrc}
            width={576}
            height={376}
            style={{
              borderRadius: 14,
              border: "1px solid rgba(0,0,0,0.08)",
              boxShadow: "0 32px 70px -34px rgba(0,0,0,0.28)",
            }}
            alt=""
          />
        </div>
      </div>
    ),
    {
      ...size,
      fonts: [
        { name: "Exposure", data: regular, weight: 400, style: "normal" },
      ],
    }
  );
}
