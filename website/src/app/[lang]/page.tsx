import { notFound } from "next/navigation";
import { Header } from "@/components/sections/header";
import { Hero } from "@/components/sections/hero";
import { Bento } from "@/components/sections/bento";
import { ModelMarquee } from "@/components/sections/model-marquee";
import { Footer } from "@/components/sections/footer";
import { isLocale } from "@/i18n/config";
import { getDictionary } from "@/i18n/get-dictionary";

export default async function Home({
  params,
}: {
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  if (!isLocale(lang)) notFound();

  const dict = await getDictionary(lang);

  return (
    <>
      <Header dict={dict.nav} locale={lang} />
      <main className="overflow-x-clip">
        <Hero dict={dict.hero} />
        <Bento dict={dict.bento} />
        <ModelMarquee dict={dict.models} />
      </main>
      <Footer dict={dict.footer} />
    </>
  );
}
