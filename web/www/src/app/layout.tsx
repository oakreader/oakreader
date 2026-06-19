import type { Metadata } from "next";
import { Inter, Fraunces, Space_Mono } from "next/font/google";
import localFont from "next/font/local";
import "./globals.css";

// Inter — clean, modern grotesque sans-serif matching fabric.so's body font
const inter = Inter({
  variable: "--font-geist-sans",
  subsets: ["latin"],
  weight: ["300", "400", "500", "600", "700"],
  style: ["normal", "italic"],
});

// Fraunces — variable serif with SOFT axis for rounded terminals
const fraunces = Fraunces({
  variable: "--font-serif",
  subsets: ["latin"],
  axes: ["SOFT", "WONK", "opsz"],
  style: ["normal", "italic"],
});

// Exposure VAR — variable display font extracted from Dia
const exposure = localFont({
  variable: "--font-exposure",
  src: [
    { path: "../../public/fonts/exposure-1.woff2", weight: "1", style: "normal" },
    { path: "../../public/fonts/exposure-50.woff2", weight: "50", style: "normal" },
    { path: "../../public/fonts/exposure-100.woff2", weight: "100", style: "normal" },
    { path: "../../public/fonts/exposure-150.woff2", weight: "150", style: "normal" },
    { path: "../../public/fonts/exposure-200.woff2", weight: "200", style: "normal" },
    { path: "../../public/fonts/exposure-250.woff2", weight: "250", style: "normal" },
    { path: "../../public/fonts/exposure-300.woff2", weight: "300", style: "normal" },
    { path: "../../public/fonts/exposure-350.woff2", weight: "350", style: "normal" },
    { path: "../../public/fonts/exposure-400.woff2", weight: "400", style: "normal" },
    { path: "../../public/fonts/exposure-450.woff2", weight: "450", style: "normal" },
    { path: "../../public/fonts/exposure-500.woff2", weight: "500", style: "normal" },
    { path: "../../public/fonts/exposure-550.woff2", weight: "550", style: "normal" },
    { path: "../../public/fonts/exposure-550-italic.woff2", weight: "550", style: "italic" },
    { path: "../../public/fonts/exposure-600.woff2", weight: "600", style: "normal" },
    { path: "../../public/fonts/exposure-650.woff2", weight: "650", style: "normal" },
    { path: "../../public/fonts/exposure-700.woff2", weight: "700", style: "normal" },
    { path: "../../public/fonts/exposure-750.woff2", weight: "750", style: "normal" },
    { path: "../../public/fonts/exposure-800.woff2", weight: "800", style: "normal" },
    { path: "../../public/fonts/exposure-850.woff2", weight: "850", style: "normal" },
    { path: "../../public/fonts/exposure-900.woff2", weight: "900", style: "normal" },
  ],
});

// ABC Favorit Mono alternative — design-oriented monospace
const spaceMono = Space_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
  weight: ["400", "700"],
  style: ["normal", "italic"],
});

const TITLE = "Oak | The Context Library for you and your agent";
const DESCRIPTION =
  "Oak keeps everything you read in one place, then puts an AI research agent on top that searches and answers across all of it — with citations you can open.";

export const metadata: Metadata = {
  title: TITLE,
  description: DESCRIPTION,
  keywords:
    "context library, AI research agent, reading app, macOS, PDF reader, knowledge base, AI research, full-text search",
  openGraph: {
    title: TITLE,
    siteName: "Oak",
    description: DESCRIPTION,
  },
  twitter: {
    card: "summary_large_image",
    title: TITLE,
    description: DESCRIPTION,
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${inter.variable} ${fraunces.variable} ${spaceMono.variable} ${exposure.variable} antialiased`}
    >
      <body className="min-h-dvh overflow-x-hidden font-sans">
        {children}
      </body>
    </html>
  );
}
