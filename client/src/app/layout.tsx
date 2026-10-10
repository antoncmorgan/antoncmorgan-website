import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Anton Morgan - Projects",
  description: "A collection of Anton Morgan's personal projects.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
