import requests
import json
import time

# =========================
# CONFIG
# =========================
API_URL = "http://localhost:8080"  # Port resmi platform (bukan 8000)
MAX_STEPS = 10

# Runtime yang tersedia di platform:
#   "wasm"     -> tool stateless ringan (default)
#   "microvm"  -> kode Python / untrusted compute (Firecracker)
#   "gui"      -> browser / GUI automation (Chromium + Playwright)
DEFAULT_RUNTIME = "microvm"


# =========================
# HEALTH CHECK
# =========================
def check_health(api_url: str) -> bool:
    """
    Cek apakah platform API sudah berjalan.
    GET /health -> {"status": "healthy", "version": "0.1.0-local", ...}
    """
    try:
        res = requests.get(f"{api_url}/health", timeout=5)
        data = res.json()
        status = data.get("status", "unknown")
        version = data.get("version", "?")
        services = data.get("services", {})
        print(f"[Health] status={status}  version={version}  services={services}")
        return status == "healthy"
    except Exception as e:
        print(f"[Health] Gagal terhubung ke platform: {e}")
        return False


# =========================
# SESSION MANAGER
# =========================
class SessionManager:
    """
    Buat sesi eksekusi ke salah satu runtime tier platform.
    POST /sessions -> {"session_id": "sess_xxx", "runtime": "...", "status": "active"}

    Catatan: session_id bersifat opsional di /execute.
    Jika tidak dikirim, platform akan otomatis membuat sesi baru.
    """
    def __init__(self, base_url: str):
        self.base_url = base_url
        self.session_id: str | None = None
        self.runtime: str | None = None

    def create(self, runtime: str = DEFAULT_RUNTIME) -> str | None:
        try:
            res = requests.post(
                f"{self.base_url}/sessions",
                json={"runtime": runtime},
                timeout=10
            )
            data = res.json()
            self.session_id = data.get("session_id")
            self.runtime = data.get("runtime")
            print(f"[Session] Dibuat: id={self.session_id}  runtime={self.runtime}")
            return self.session_id
        except Exception as e:
            print(f"[Session] Gagal membuat sesi: {e}")
            return None


# =========================
# MEMORY
# =========================
class Memory:
    def __init__(self):
        self.messages = []

    def add(self, role: str, content: str):
        self.messages.append({"role": role, "content": content})

    def get(self) -> list:
        return self.messages[-10:]


# =========================
# TOOL CLIENT
# =========================
class ToolClient:
    """
    Kirim tool execution ke platform.

    POST /execute
    Body  : { "tool": str, "input": dict, "session_id"?: str }
    Respon: { "job_id": str, "status": "completed"|"failed",
              "output"?: str, "error_message"?: str, "duration_ms": int }
    """
    def __init__(self, base_url: str, session_manager: SessionManager):
        self.base_url = base_url
        self.session_manager = session_manager

    def execute(self, tool: str, input_data: dict) -> dict:
        payload = {
            "tool": tool,
            "input": input_data,
        }
        # Sertakan session_id jika sudah ada
        if self.session_manager.session_id:
            payload["session_id"] = self.session_manager.session_id

        try:
            res = requests.post(
                f"{self.base_url}/execute",
                json=payload,
                timeout=60
            )
            data = res.json()

            # Tangani format respon platform:
            # { job_id, status, output, duration_ms }  <- sukses
            # { job_id, status, error_message, duration_ms } <- gagal
            job_id      = data.get("job_id", "?")
            status      = data.get("status", "unknown")
            duration_ms = data.get("duration_ms", 0)

            if status == "completed":
                output = data.get("output", "")
                print(f"[Tool] job={job_id}  status={status}  {duration_ms}ms")
                return {"status": "completed", "output": output, "job_id": job_id}
            else:
                error = data.get("error_message", "unknown error")
                print(f"[Tool] job={job_id}  status={status}  error={error}  {duration_ms}ms")
                return {"status": "failed", "error": error, "job_id": job_id}

        except Exception as e:
            return {"status": "error", "error": str(e)}


# =========================
# TOOL REGISTRY (dari platform)
# =========================
def load_tools(api_url: str) -> list:
    """
    Platform belum menyediakan endpoint /tools (masih dalam roadmap).
    Untuk sekarang, kembalikan daftar tool yang diketahui dari dokumentasi.

    Tool yang tersedia berdasarkan runtime-reference.md:
      - python_run  -> microvm (Firecracker)
      - browser_open -> gui (Chromium + Playwright)
      - (tool lain unknown) -> default wasm
    """
    known_tools = [
        {"name": "python_run",   "runtime": "microvm", "description": "Jalankan kode Python di Firecracker VM"},
        {"name": "browser_open", "runtime": "gui",     "description": "Buka URL di browser Chromium"},
    ]
    print(f"[Tools] Menggunakan {len(known_tools)} tool dari dokumentasi platform.")
    return known_tools


# =========================
# PARSER
# =========================
def parse_action(response: str) -> dict | None:
    """
    Coba parse JSON dari respon LLM.
    Jika ada field 'tool', anggap sebagai perintah tool execution.
    """
    try:
        data = json.loads(response)
        if "tool" in data:
            return data
    except Exception:
        pass
    return None


# =========================
# SIMPLE LLM  (GANTI INI dengan OpenAI / Claude / dll)
# =========================
def simple_llm(messages: list, tools: list) -> str:
    """
    Contoh router sederhana — ganti dengan panggilan LLM sungguhan.

    Format output yang diharapkan jika ingin memanggil tool:
        {"tool": "<nama_tool>", "input": { ... }}

    Jika tidak ada tool yang dipanggil, kembalikan teks biasa.
    """
    last_user = messages[-1]["content"]

    if "calculate" in last_user or any(op in last_user for op in ["*", "+", "-", "/"]):
        expr = last_user.split("calculate")[-1].strip() if "calculate" in last_user else last_user.strip()
        return json.dumps({
            "tool": "python_run",
            "input": {
                "code": f"print({expr})"
            }
        })

    if "open" in last_user or "browse" in last_user or "http" in last_user:
        # Coba ambil URL dari input
        words = last_user.split()
        url = next((w for w in words if w.startswith("http")), "https://google.com")
        return json.dumps({
            "tool": "browser_open",
            "input": {
                "url": url
            }
        })

    return "Saya tidak memerlukan tool. Jawaban: " + last_user


# =========================
# AGENT LOOP
# =========================
class Agent:
    def __init__(self, api_url: str):
        self.memory = Memory()
        self.session_manager = SessionManager(api_url)
        self.tool_client = ToolClient(api_url, self.session_manager)
        self.tools = load_tools(api_url)

        # Buat sesi awal (opsional — /execute akan auto-buat jika tidak ada)
        self.session_manager.create(runtime=DEFAULT_RUNTIME)

    def run(self, user_input: str) -> str:
        self.memory.add("user", user_input)

        for step in range(MAX_STEPS):
            print(f"\n--- Step {step + 1} ---")
            response = simple_llm(self.memory.get(), self.tools)
            print(f"LLM: {response}")

            action = parse_action(response)
            if action:
                tool_name  = action["tool"]
                tool_input = action.get("input", {})
                print(f"Memanggil tool: {tool_name}  input={tool_input}")

                result = self.tool_client.execute(tool_name, tool_input)
                print(f"Hasil tool: {result}")

                # Simpan output ke memori agar LLM tahu hasilnya
                result_text = result.get("output") or result.get("error") or json.dumps(result)
                self.memory.add("tool", result_text)

                time.sleep(0.5)
            else:
                print(f"Jawaban akhir: {response}")
                return response

        return "Batas langkah maksimum tercapai."


# =========================
# MAIN
# =========================
if __name__ == "__main__":
    print("=" * 50)
    print("Agent — xianying-boss/platform-docs")
    print("=" * 50)

    # Cek kesehatan platform sebelum mulai
    if not check_health(API_URL):
        print("\n[PERINGATAN] Platform tidak sehat atau tidak berjalan.")
        print("Jalankan dulu:  cd sandbox-platform && make dev")
        print("Melanjutkan meskipun demikian...\n")

    agent = Agent(API_URL)

    while True:
        try:
            user_input = input("\nUser: ").strip()
            if not user_input:
                continue
            if user_input.lower() in ("exit", "quit", "keluar"):
                print("Sampai jumpa!")
                break
            result = agent.run(user_input)
            print(f"\nAgent: {result}")
        except KeyboardInterrupt:
            print("\nDihentikan oleh pengguna.")
            break
