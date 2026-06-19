import { Header } from "@/components/sections/header";
import { Hero } from "@/components/sections/hero";
import { Bento } from "@/components/sections/bento";
import { ModelMarquee } from "@/components/sections/model-marquee";
import { Footer } from "@/components/sections/footer";

export default function Home() {
  return (
    <>
      <Header />
      <main className="overflow-x-clip">
        <Hero />
        <Bento />
        <ModelMarquee />
      </main>
      <Footer />
    </>
  );
}
