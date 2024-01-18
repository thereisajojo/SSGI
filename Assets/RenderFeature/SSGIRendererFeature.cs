using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using ProfilingScope = UnityEngine.Rendering.ProfilingScope;

[Serializable]
public class SSGISettings
{
    public LayerMask LayerMask;
    public FilterMode FilterMode;
    public bool SampleBack;
    
    // SAMPLE
    [Min(1)] public float DownSample = 2f;
    [Min(0)] public float StepScale = 0.3f;
    // [NonSerialized] [Min(0)] public float Thickness = 0.5f;
    
    // BLUR
    // [NonSerialized] public float JitterScale = 1f;
    public float BilateralFilterStrength = 0f;
    [Min(0)] public float BlurRadius = 1f;
}

[DisallowMultipleRendererFeature]
public class SSGIRendererFeature : ScriptableRendererFeature
{
    public Material SSGIMaterial;
    public SSGISettings Settings;

    private SSGIRenderPass m_SSGIRenderPass;
    private DrawOnlyColorPass m_DrawOnlyColorPass;

    private RenderTexture ssgiCurrent;
    private RenderTexture ssgiPrevious;

    private void GetSSGITexture(RenderTextureDescriptor descriptor)
    {
        const int height = 600;
        int width = (int)((float)height * descriptor.width / descriptor.height);
        
        if (ssgiCurrent != null)
        {
            if (ssgiCurrent.width != width || ssgiCurrent.height != height)
            {
                ssgiCurrent.Release();
                ssgiPrevious.Release();
            }
            else
            {
                return;
            }
        }
        
        ssgiCurrent = new RenderTexture(width, height, 16, descriptor.graphicsFormat);
        ssgiCurrent.filterMode = FilterMode.Bilinear;
        ssgiCurrent.name = "ssgi_0";
        ssgiPrevious = new RenderTexture(ssgiCurrent.descriptor);
        ssgiPrevious.filterMode = FilterMode.Bilinear;
        ssgiPrevious.name = "ssgi_1";

        CommandBuffer cmd = CommandBufferPool.Get();
        cmd.SetRenderTarget(ssgiCurrent);
        cmd.ClearRenderTarget(RTClearFlags.All, new Color(0, 0, 0, 0), 1f, 0x00);
        cmd.SetRenderTarget(ssgiPrevious);
        cmd.ClearRenderTarget(RTClearFlags.All, new Color(0, 0, 0, 0), 1f, 0x00);
        Graphics.ExecuteCommandBuffer(cmd);
        CommandBufferPool.Release(cmd);
    }

    private void SwapRt()
    {
        (ssgiCurrent, ssgiPrevious) = (ssgiPrevious, ssgiCurrent);
    }

    /// <inheritdoc/>
    public override void Create()
    {
        m_DrawOnlyColorPass = new DrawOnlyColorPass(Settings.LayerMask);
        m_DrawOnlyColorPass.renderPassEvent = RenderPassEvent.BeforeRenderingOpaques;
        
        m_SSGIRenderPass = new SSGIRenderPass();

        // Configures where the render pass should be injected.
        m_SSGIRenderPass.renderPassEvent = RenderPassEvent.BeforeRenderingOpaques;

        ssgiCurrent = null;
        ssgiPrevious = null;
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // if (renderingData.cameraData.cameraType != CameraType.Game) return;
        
        // GetSSGITexture(renderingData.cameraData.cameraTargetDescriptor);
        m_DrawOnlyColorPass.Setup(Settings);
        bool shouldAdd = m_SSGIRenderPass.Setup(renderer, SSGIMaterial, Settings, ssgiCurrent, ssgiPrevious);
        if (shouldAdd)
        {
            renderer.EnqueuePass(m_DrawOnlyColorPass);
            renderer.EnqueuePass(m_SSGIRenderPass);
        }
        // SwapRt();
    }
}

internal class SSGIRenderPass : ScriptableRenderPass
{
    private ProfilingSampler m_ProfilingSampler = new ProfilingSampler("SSGI");
    private ScriptableRenderer m_Renderer;
    private Material m_Material;
    private SSGISettings m_Settings;

    // private RenderTexture m_current;
    // private RenderTexture m_previous;

    private static readonly int s_TempRT0ID = Shader.PropertyToID("_SSGI_TempRT_0");
    private static readonly int s_TempRT1ID = Shader.PropertyToID("_SSGI_TempRT_1");
    private static readonly int s_CameraViewTopLeftCornerID = Shader.PropertyToID("_CameraViewTopLeftCorner");
    private static readonly int s_CameraViewXExtentID = Shader.PropertyToID("_CameraViewXExtent");
    private static readonly int s_CameraViewYExtentID = Shader.PropertyToID("_CameraViewYExtent");
    private static readonly int s_ProjectionParams2ID = Shader.PropertyToID("_ProjectionParams2");
    private static readonly int s_StepScaleID = Shader.PropertyToID("_StepScale");
    private static readonly int s_ThicknessID = Shader.PropertyToID("_Thickness");
    private static readonly int s_FrameIndexID = Shader.PropertyToID("_FrameIndex");
    private static readonly int s_BilateralFilterStrengthID = Shader.PropertyToID("_BilateralFilterFactor");
    private static readonly int s_BlurRadiusID = Shader.PropertyToID("_BlurRadius");

    public bool Setup(ScriptableRenderer renderer, Material material, SSGISettings settings, RenderTexture current, RenderTexture previous)
    {
        m_Renderer = renderer;
        m_Material = material;
        m_Settings = settings;
        // m_current = current;
        // m_previous = previous;

        ConfigureInput(ScriptableRenderPassInput.Normal);

        return material != null;
    }

    private static void GetSHVectorArrays(Vector4[] result, ref SphericalHarmonicsL2 sh)
    {
        for (int c = 0; c < 3; c++)
        {
            result[c].Set(sh[c, 3], sh[c, 1], sh[c, 2], sh[c, 0] - sh[c, 6]);
        }

        for (int c = 0; c < 3; c++)
        {
            result[3 + c].Set(sh[c, 4], sh[c, 5], sh[c, 6] * 3f, sh[c, 7]);
        }

        result[6].Set(sh[0, 8], sh[1, 8], sh[2, 8], 1f);
    }

    // This method is called before executing the render pass.
    // It can be used to configure render targets and their clear state. Also to create temporary render target textures.
    // When empty this render pass will render to the active camera render target.
    // You should never call CommandBuffer.SetRenderTarget. Instead call <c>ConfigureTarget</c> and <c>ConfigureClear</c>.
    // The render pipeline will ensure target setup and clearing happens in a performant manner.
    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        var descriptor = renderingData.cameraData.cameraTargetDescriptor;
        descriptor.width = (int)(descriptor.width / m_Settings.DownSample);
        descriptor.height = (int)(descriptor.height / m_Settings.DownSample);
        cmd.GetTemporaryRT(s_TempRT0ID, descriptor, m_Settings.FilterMode);
        cmd.GetTemporaryRT(s_TempRT1ID, descriptor, m_Settings.FilterMode);

        // m_Material.SetTexture("_LastSSGI", m_previous);
        m_Material.SetFloat(s_StepScaleID, m_Settings.StepScale);
        // m_Material.SetFloat(s_ThicknessID, m_Settings.Thickness);
        m_Material.SetInt(s_FrameIndexID, Time.frameCount);
        m_Material.SetFloat(s_BilateralFilterStrengthID, m_Settings.BilateralFilterStrength);

        if (m_Settings.SampleBack)
        {
            m_Material.EnableKeyword("_SAMPLE_BACK");
        }
        else
        {
            m_Material.DisableKeyword("_SAMPLE_BACK");
        }

        // 计算各种矩阵
        Matrix4x4 view = renderingData.cameraData.GetViewMatrix();
        Matrix4x4 proj = renderingData.cameraData.GetProjectionMatrix();
        Matrix4x4 vp = proj * view;

        // 将camera view space 的平移置为0，用来计算world space下相对于相机的vector
        Matrix4x4 cView = view;
        cView.SetColumn(3, new Vector4(0.0f, 0.0f, 0.0f, 1.0f));
        Matrix4x4 cViewProj = proj * cView;
        m_Material.SetMatrix("_SSGI_MATRIX_VP", cViewProj);

        // TAA
        // Matrix4x4 taaViewProj = Jitter.CalculateJitterProjectionMatrix(ref renderingData.cameraData, m_Settings.JitterScale) * cView;
        // m_Material.SetMatrix("_TAA_MATRIX_VP", taaViewProj);

        // 计算viewProj逆矩阵，即从裁剪空间变换到世界空间
        Matrix4x4 cViewProjInv = cViewProj.inverse;

        // 计算世界空间下，近平面四个角的坐标
        // var near = renderingData.cameraData.camera.nearClipPlane;
        Vector4 topLeftCorner = cViewProjInv.MultiplyPoint(new Vector4(-1.0f, 1.0f, -1.0f, 1.0f));
        Vector4 topRightCorner = cViewProjInv.MultiplyPoint(new Vector4(1.0f, 1.0f, -1.0f, 1.0f));
        Vector4 bottomLeftCorner = cViewProjInv.MultiplyPoint(new Vector4(-1.0f, -1.0f, -1.0f, 1.0f));

        // 计算相机近平面上方向向量
        Vector4 cameraXExtent = topRightCorner - topLeftCorner;
        Vector4 cameraYExtent = bottomLeftCorner - topLeftCorner;

        float near = renderingData.cameraData.camera.nearClipPlane;

        // 发送ReconstructViewPos参数
        m_Material.SetVector(s_CameraViewTopLeftCornerID, topLeftCorner);
        m_Material.SetVector(s_CameraViewXExtentID, cameraXExtent);
        m_Material.SetVector(s_CameraViewYExtentID, cameraYExtent);
        m_Material.SetVector(s_ProjectionParams2ID,
            new Vector4(1.0f / near, renderingData.cameraData.worldSpaceCameraPos.x, renderingData.cameraData.worldSpaceCameraPos.y,
                renderingData.cameraData.worldSpaceCameraPos.z));

        // 环境光球谐
        var sh = RenderSettings.ambientProbe;
        Vector4[] shData = new Vector4[7];
        GetSHVectorArrays(shData, ref sh);
        m_Material.SetVectorArray("_AmbientSH", shData);

        ConfigureTarget(m_Renderer.cameraColorTarget);
        ConfigureClear(ClearFlag.None, Color.white);
    }

    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        CommandBuffer cmd = CommandBufferPool.Get();
        using (new ProfilingScope(cmd, m_ProfilingSampler))
        {
            // Sample GI
            cmd.Blit(m_Renderer.cameraColorTarget, s_TempRT0ID, m_Material, 0);
            
            // Blur horizontal
            cmd.SetGlobalVector(s_BlurRadiusID, new Vector4(m_Settings.BlurRadius, 0, 0, 0));
            cmd.Blit(s_TempRT0ID, s_TempRT1ID, m_Material, 1);
            
            // Blur vertical
            cmd.SetGlobalVector(s_BlurRadiusID, new Vector4(0, m_Settings.BlurRadius, 0, 0));
            cmd.Blit(s_TempRT1ID, s_TempRT0ID, m_Material, 1);

            cmd.SetGlobalTexture("_SSGITexture", s_TempRT0ID);

            // cmd.SetRenderTarget(m_Renderer.cameraColorTarget);
        }

        context.ExecuteCommandBuffer(cmd);
        CommandBufferPool.Release(cmd);
    }

    private void Render(CommandBuffer cmd, RenderTargetIdentifier target, int pass)
    {
        cmd.SetRenderTarget(
            target,
            RenderBufferLoadAction.DontCare,
            RenderBufferStoreAction.Store,
            target,
            RenderBufferLoadAction.DontCare,
            RenderBufferStoreAction.DontCare
        );
        cmd.DrawMesh(RenderingUtils.fullscreenMesh, Matrix4x4.identity, m_Material, 0, pass);
    }

    // Cleanup any allocated resources that were created during the execution of this render pass.
    public override void OnCameraCleanup(CommandBuffer cmd)
    {
        cmd.ReleaseTemporaryRT(s_TempRT0ID);
        cmd.ReleaseTemporaryRT(s_TempRT1ID);
    }
}

internal class DrawOnlyColorPass : ScriptableRenderPass
{
    private SSGISettings m_settings;
    private FilteringSettings m_filtering;
    private ShaderTagId m_shaderTagId = new ShaderTagId("OnlyColor");
    
    private static readonly int s_onlyColorTextureID = Shader.PropertyToID("_OnlyColorTexture");

    public void Setup(SSGISettings settings)
    {
        m_settings = settings;
    }

    public DrawOnlyColorPass(LayerMask layerMask)
    {
        m_filtering = new FilteringSettings(RenderQueueRange.opaque, layerMask);
    }

    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        var descriptor = renderingData.cameraData.cameraTargetDescriptor;
        descriptor.width = (int)(descriptor.width / m_settings.DownSample);
        descriptor.height = (int)(descriptor.height / m_settings.DownSample);
        cmd.GetTemporaryRT(s_onlyColorTextureID, descriptor);
        
        ConfigureTarget(s_onlyColorTextureID);
        ConfigureClear(ClearFlag.All, Color.black);
    }

    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        SortingCriteria sortingCriteria = renderingData.cameraData.defaultOpaqueSortFlags;
        var drawingSettings = CreateDrawingSettings(m_shaderTagId, ref renderingData, sortingCriteria);
        context.DrawRenderers(renderingData.cullResults, ref drawingSettings, ref m_filtering);
    }
}

internal static class Jitter
{
    internal static float GetHalton(int index, int radix)
    {
        float result = 0.0f;
        float fraction = 1.0f / radix;
        while (index > 0)
        {
            result += (index % radix) * fraction;

            index /= radix;
            fraction /= radix;
        }

        return result;
    }

    // get [-0.5, 0.5] jitter vector2
    internal static Vector2 CalculateJitter(int frameIndex)
    {
        float jitterX = GetHalton((frameIndex & 1023) + 1, 2) - 0.5f;
        float jitterY = GetHalton((frameIndex & 1023) + 1, 3) - 0.5f;

        return new Vector2(jitterX, jitterY);
    }

    internal static Matrix4x4 CalculateJitterProjectionMatrix(ref CameraData cameraData, float jitterScale = 1.0f)
    {
        Matrix4x4 mat = cameraData.GetProjectionMatrix();

        int taaFrameIndex = Time.frameCount;

        float actualWidth = cameraData.camera.pixelWidth;
        float actualHeight = cameraData.camera.pixelHeight;

        Vector2 jitter = CalculateJitter(taaFrameIndex) * jitterScale;

        mat.m02 += jitter.x * (2.0f / actualWidth);
        mat.m12 += jitter.y * (2.0f / actualHeight);

        return mat;
    }
}