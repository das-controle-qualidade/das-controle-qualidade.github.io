// Gerencia contas do sistema (criar, excluir, redefinir senha).
// Roda no servidor do Supabase com a chave secreta, que nunca vai para o site.
// Só aceita pedidos de quem estiver logado como administrador.
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function resposta(corpo: unknown, status = 200) {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

// Chave secreta fornecida pelo próprio Supabase dentro da função.
function chaveSecreta(): string {
  const legado = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legado) return legado;
  try {
    const chaves = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}");
    return chaves.default || Object.values(chaves)[0] as string;
  } catch {
    return "";
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return resposta({ error: "Método não permitido." }, 405);

  try {
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      chaveSecreta(),
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    // Quem está pedindo?
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: quem, error: erroSessao } = await admin.auth.getUser(token);
    if (erroSessao || !quem?.user) return resposta({ error: "Sessão inválida. Entre novamente." }, 401);

    const { data: perfil } = await admin.from("perfis").select("papel").eq("id", quem.user.id).maybeSingle();
    if (perfil?.papel !== "admin") {
      return resposta({ error: "Somente o administrador pode gerenciar usuários." }, 403);
    }

    const corpo = await req.json().catch(() => ({}));
    const acao = String(corpo.acao || "");

    if (acao === "criar") {
      const email = String(corpo.email || "").trim().toLowerCase();
      const senha = String(corpo.senha || "");
      const nome = String(corpo.nome || "").trim();
      const papel = corpo.papel === "admin" ? "admin" : "user";
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return resposta({ error: "Informe um e-mail válido." }, 400);
      if (senha.length < 8) return resposta({ error: "A senha inicial deve ter pelo menos 8 caracteres." }, 400);

      const { data, error } = await admin.auth.admin.createUser({
        email,
        password: senha,
        email_confirm: true,
        user_metadata: { nome: nome || email.split("@")[0] },
        app_metadata: { papel },
      });
      if (error) {
        const msg = /already|registered|exists/i.test(error.message) ? "Já existe uma conta com este e-mail." : error.message;
        return resposta({ error: msg }, 400);
      }
      return resposta({ ok: true, id: data.user?.id });
    }

    if (acao === "senha") {
      const id = String(corpo.id || "");
      const senha = String(corpo.senha || "");
      if (!id) return resposta({ error: "Usuário não informado." }, 400);
      if (senha.length < 8) return resposta({ error: "A senha precisa ter pelo menos 8 caracteres." }, 400);
      const { error } = await admin.auth.admin.updateUserById(id, { password: senha });
      if (error) return resposta({ error: error.message }, 400);
      return resposta({ ok: true });
    }

    if (acao === "excluir") {
      const id = String(corpo.id || "");
      if (!id) return resposta({ error: "Usuário não informado." }, 400);
      if (id === quem.user.id) return resposta({ error: "Você não pode excluir a própria conta." }, 400);
      const { error } = await admin.auth.admin.deleteUser(id);
      if (error) return resposta({ error: error.message }, 400);
      return resposta({ ok: true });
    }

    return resposta({ error: "Ação desconhecida." }, 400);
  } catch (e) {
    return resposta({ error: (e as Error)?.message || String(e) }, 500);
  }
});
