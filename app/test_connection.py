import os
import litellm

# Explicitly use the safe version pinned earlier
# Check if model access works for your project
def test_vertex_anthropic():
    project_id = os.environ.get("PROJECT_ID", "YOUR_PROJECT_ID")
    region = "us-central1"
    
    # Model name format for litellm: vertex_ai/model-name
    model = "vertex_ai/claude-3-5-sonnet@20240620"
    
    print(f"Testing connectivity to {model} in project {project_id}...")
    
    try:
        response = litellm.completion(
            model=model,
            messages=[{"role": "user", "content": "Hello, are you active in Vertex AI?"}],
            vertex_project=project_id,
            vertex_location=region
        )
        print("Response received successfully!")
        print(response.choices[0].message.content)
        return True
    except Exception as e:
        print(f"Error communicating with Vertex AI: {e}")
        return False

if __name__ == "__main__":
    test_vertex_anthropic()
