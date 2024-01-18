using UnityEngine;

public class ShowFPS : MonoBehaviour
{
    public float m_UpdateShowDeltaTime = 0.5f;//更新帧率的时间间隔;
    public int FontSize = 30;
    
    private float m_LastUpdateShowTime = 0f;  //上一次更新帧率的时间;
    private int m_FrameUpdate = 0;//帧数;  
    private int m_FPS = 0;//帧率
    private string text;

    private void Start()
    {
        m_LastUpdateShowTime = Time.realtimeSinceStartup;

        Application.targetFrameRate = 999;
    }

    private void Update()
    {
        m_FrameUpdate++;
        if (Time.realtimeSinceStartup - m_LastUpdateShowTime >= m_UpdateShowDeltaTime)
        {
            //FPS = 某段时间内的总帧数 / 某段时间
            m_FPS = (int)(m_FrameUpdate / (Time.realtimeSinceStartup - m_LastUpdateShowTime));
            m_FrameUpdate = 0;
            m_LastUpdateShowTime = Time.realtimeSinceStartup;
            text = $"FPS: {m_FPS}";
        }
    }

    private void OnGUI()
    {
        float screenScale = Screen.height / 1080f;
        GUILayout.Space(30 * screenScale);
        GUIStyle style = new GUIStyle
        {
            fontSize = (int)(screenScale * FontSize)
        };
        style.normal.textColor = Color.red;
        GUILayout.Label(text, style);
    }
}
